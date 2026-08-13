import AppKit
import CoreGraphics
import Foundation
import QuartzCore

public enum CaptureOverlayOutcome: Sendable {
    case cancelled
    case copied(CGImage, selection: CaptureSelection)
    case saved(CGImage, selection: CaptureSelection)
    case pinned(CGImage, frame: CGRect, selection: CaptureSelection)
}

/// 区域反复截帧（由 SessionCoordinator 注入 CaptureService，Overlay 不碰 SCK）。
public typealias RegionCaptureHandler = @Sendable (CaptureSelection, [CGWindowID]) async throws -> CGImage

/// 截图遮罩：图层化渲染 + 选区固定后标注工具条。
/// REQ: C-01, C-02, C-06 / UI_SPEC §3
@MainActor
public final class CaptureOverlayController: NSObject, CaptureToolbarDelegate {
    public var onFinish: ((CaptureOverlayOutcome) -> Void)?
    public var onNeedUpgrade: (() -> Void)?
    /// 长截滚动态变化（供 SessionCoordinator 更新状态机）。
    public var onScrollCaptureActiveChange: ((Bool) -> Void)?
    public var annotationEnabled = true
    public var autoCopyOnSelect = false
    public var autoSaveOnSelect = false
    /// 框选确认后直接进入长截滚动采集（菜单「长截图」）。
    public var enterScrollAfterSelect = false
    /// 区域截帧；未注入时工具条「长截图」不可用。
    public var captureRegion: RegionCaptureHandler?

    private var panels: [OverlayPanel] = []
    private var frames: [ScreenFrame] = []
    private let geometry = ScreenGeometry()
    private let windows = WindowTracker()
    private let exporter = ImageExporter()
    private let annotations = AnnotationController()
    private let gate: FeatureGateProtocol = FeatureGate.shared

    private var selection: CaptureSelection?
    private var selectionLocked = false
    private var drag = OverlayDragSession()
    private var hoverWindow: WindowHit?
    private var toolbar: CaptureToolbar?
    fileprivate var isScrollCapturing = false
    private var scrollPreviewCanvas: CGImage?
    private var scrollTask: Task<Void, Never>?
    private var scrollWheelMonitor: Any?
    /// 长截穿透时本地 monitor 常收不到，用全局 Esc/右键结束并导出。
    private var scrollGlobalKeyMonitor: Any?
    private var scrollGlobalRightClickMonitor: Any?
    /// iShot：停滚 60ms → scrollFinished 再截一帧（不退出）。
    private var scrollIdleTimer: Timer?
    private var scrollCaptureBusy = false
    private var scrollNeedsRecapture = false
    /// iShot `startAutoScroll:`：定时 CGEvent 注入滚轮。
    private var scrollAutoTimer: Timer?
    private var isAutoScrolling = false
    private var scrollSidePreview: ScrollCapturePreview?
    private var scrollDoneBar: ScrollCaptureDoneBar?
    /// 有状态拼接会话（帧数组 + 偏移）。
    private var scrollStitchSession: ScrollStitchSession?
    /// 长截完成后的浮动预览（全分辨率另存）。
    private var isFloatingResult = false
    private var floatingFullImage: CGImage?
    private var activeTool: CaptureAnnotateTool?
    private var shapeStyle: CaptureShapeStyle = .rect
    private var arrowStyle: CaptureArrowStyle = .arrow
    private var mosaicStyle: CaptureMosaicStyle = .mosaic
    private var penStyle: CapturePenStyle = .pen
    private var isColorPicking = false
    private var colorHUD: ColorSampleHUD?
    private var magnifierHUD: MagnifierHUD?
    private var lastSampledColor: NSColor?
    private var draftShape: Shape?
    private var annotateStart: CGPoint?
    private var moveGrabStart: CGPoint?
    private var moveOriginRect: CGRect?
    private var resizeHandle: SelectionResizeHandle?
    private var resizeGrabStart: CGPoint?
    private var resizeOriginRect: CGRect?
    private var resizeStartShapes: [Shape] = []

    private var lastHoverSample = Date.distantPast
    private let hoverInterval: TimeInterval = 1.0 / 30.0
    private var keyMonitor: Any?
    private var rightClickMonitor: Any?
    /// 长截浮动结果时额外装全局 Esc（菜单栏 App 失焦后本地 monitor 常收不到）。
    private var floatingEscMonitor: Any?
    private var isEditingText = false
    private var pendingTextLocal: CGPoint?
    private weak var textHostView: OverlayView?
    private var editingShapeID: UUID?
    private var draggingTextID: UUID?
    private var dragTextStart: CGPoint?
    private var dragTextOrigin: CGPoint?
    private var textDragCheckpointed = false
    private let textFontSize: CGFloat = 18
    private let textColor = NSColor.systemRed

    private var isOCRSelecting = false
    private var ocrTask: Task<Void, Never>?
    private weak var ocrHostView: OverlayView?
    private var codeResultBar: OCRCodeResultBar?

    public override init() {
        super.init()
    }

    public func present(
        frames: [ScreenFrame],
        initialSelection: CaptureSelection? = nil,
        enterScrollAfterSelect: Bool = false
    ) {
        dismiss()
        self.enterScrollAfterSelect = enterScrollAfterSelect
        self.frames = frames
        annotations.reset()
        for frame in frames {
            let panel = OverlayPanel(
                contentRect: frame.logicalBounds,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            let view = OverlayView(frame: NSRect(origin: .zero, size: frame.logicalBounds.size))
            view.screenFrame = frame
            view.controller = self
            view.installLayers()
            panel.contentView = view
            panel.setFrame(frame.logicalBounds, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        // 优先把鼠标所在屏的遮罩设为 key，避免副屏首拖只激活窗口、选区无效。
        let mouse = NSEvent.mouseLocation
        let keyPanel = panels.first { $0.frame.contains(mouse) } ?? panels.first
        keyPanel?.makeKeyAndOrderFront(nil)
        if let view = keyPanel?.contentView as? OverlayView {
            keyPanel?.makeFirstResponder(view)
        }
        installEscapeHatches()
        if let initialSelection, let locked = Self.resolvedSelection(initialSelection, in: frames) {
            selection = locked
            finishSelection()
        } else {
            syncLayers()
        }
    }

    /// 将上次选区裁到当前帧的有效范围；屏幕消失或过小则失败。
    private static func resolvedSelection(_ sel: CaptureSelection, in frames: [ScreenFrame]) -> CaptureSelection? {
        guard let frame = frames.first(where: { $0.screenID == sel.screenID }) else { return nil }
        let clamped = sel.logicalRect.intersection(frame.logicalBounds)
        guard clamped.width >= 2, clamped.height >= 2 else { return nil }
        return CaptureSelection(screenID: sel.screenID, logicalRect: clamped)
    }

    public func dismiss() {
        stopScrollCapture(commit: false)
        exitOCRMode()
        closeTextEditor(commit: false)
        removeEscapeHatches()
        toolbar?.orderOut(nil)
        toolbar?.close()
        toolbar = nil
        dismissScrollSidePreview()
        dismissScrollDoneBar()
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        selection = nil
        selectionLocked = false
        drag.reset()
        hoverWindow = nil
        activeTool = nil
        shapeStyle = .rect
        arrowStyle = .arrow
        mosaicStyle = .mosaic
        penStyle = .pen
        enterScrollAfterSelect = false
        isFloatingResult = false
        floatingFullImage = nil
        exitColorPick(updateToolbar: false)
        hideMagnifier()
        draftShape = nil
        annotateStart = nil
        moveGrabStart = nil
        moveOriginRect = nil
        clearResizeSession()
    }

    private func clearResizeSession() {
        resizeHandle = nil
        resizeGrabStart = nil
        resizeOriginRect = nil
        resizeStartShapes = []
    }

    private func installEscapeHatches() {
        removeEscapeHatches()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.isEditingText {
                if event.keyCode == 53 {
                    self.closeTextEditor(commit: false)
                    return nil
                }
                return event
            }
            if self.isOCRSelecting {
                if event.keyCode == 53 {
                    self.exitOCRMode()
                    return nil
                }
                let cmd = event.modifierFlags.contains(.command)
                // 显式复制选中 OCR 文本，避免落到「复制整图」或 TextView 富文本空拷
                if cmd && event.keyCode == 8 {
                    if self.copyOCRSelection() {
                        return nil
                    }
                    return event
                }
                if cmd && event.keyCode == 0 {
                    self.selectAllOCR()
                    return nil
                }
                return event
            }
            if event.keyCode == 53 {
                self.handleEscape()
                return nil
            }
            let cmd = event.modifierFlags.contains(.command)
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            let prefs = HotKeyPreferences.shared

            // 取色中：可改绑复制 / 切换格式
            if self.isColorPicking {
                if prefs.chord(for: .overlayColorCopy).matches(event) {
                    self.copySampledColor()
                    return nil
                }
                if prefs.chord(for: .overlayColorToggle).matches(event) {
                    self.colorHUD?.toggleFormat()
                    return nil
                }
            }

            // 选区方向键微调（Shift = 10pt）
            if self.selectionLocked, !self.isEditingText, !self.isOCRSelecting, !cmd {
                let step: CGFloat = mods.contains(.shift) ? 10 : 1
                switch event.keyCode {
                case 123:
                    self.nudgeSelection(dx: -step, dy: 0)
                    return nil
                case 124:
                    self.nudgeSelection(dx: step, dy: 0)
                    return nil
                case 125:
                    self.nudgeSelection(dx: 0, dy: -step)
                    return nil
                case 126:
                    self.nudgeSelection(dx: 0, dy: step)
                    return nil
                default:
                    break
                }
            }

            if prefs.chord(for: .overlayQuickSave).matches(event) {
                self.commitQuickSave()
                return nil
            }
            if prefs.chord(for: .overlaySaveAs).matches(event) {
                self.commitSave()
                return nil
            }

            switch event.keyCode {
            case 36, 76:
                if self.isScrollCapturing {
                    self.stopScrollCapture(commit: true)
                    return nil
                }
                self.commitCopy()
                return nil
            case 8 where cmd:
                self.commitCopy()
                return nil
            case 6 where cmd:
                if event.modifierFlags.contains(.shift) {
                    self.toolbarRedo()
                } else {
                    self.toolbarUndo()
                }
                return nil
            case 17 where cmd:
                self.commitPin()
                return nil
            default:
                return event
            }
        }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
            guard let self, !self.isEditingText else { return nil }
            if self.isScrollCapturing {
                self.stopScrollCapture(commit: self.scrollStitchSession != nil)
                return nil
            }
            self.cancel()
            return nil
        }
    }

    private func removeEscapeHatches() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
            self.rightClickMonitor = nil
        }
        if let floatingEscMonitor {
            NSEvent.removeMonitor(floatingEscMonitor)
            self.floatingEscMonitor = nil
        }
    }

    private func installFloatingEscMonitor() {
        if let floatingEscMonitor {
            NSEvent.removeMonitor(floatingEscMonitor)
            self.floatingEscMonitor = nil
        }
        floatingEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isFloatingResult, event.keyCode == 53 else { return event }
            self.cancel()
            return nil
        }
    }

    private func handleEscape() {
        if isScrollCapturing {
            // 对齐 iShot：Esc 导出已有画布；尚无帧则整段取消
            let hadSession = scrollStitchSession != nil
            stopScrollCapture(commit: hadSession)
            if !hadSession {
                cancel()
            }
            return
        }
        // 长截浮动结果：Esc 一律关闭，不先清工具
        if isFloatingResult {
            cancel()
            return
        }
        if isEditingText {
            closeTextEditor(commit: false)
            return
        }
        if isOCRSelecting {
            exitOCRMode()
            return
        }
        if isColorPicking {
            exitColorPick()
            return
        }
        if selectionLocked, activeTool != nil {
            activeTool = nil
            toolbar?.setSelectedTool(nil)
            draftShape = nil
            syncLayers()
        } else {
            cancel()
        }
    }

    // MARK: - Mouse (from OverlayView)

    fileprivate func mouseDown(at global: CGPoint) {
        if isScrollCapturing { return }
        if isOCRSelecting { return }
        if isEditingText {
            // 点在输入框外：提交当前文字
            finishTextInput(textHostView?.currentText() ?? "")
            return
        }
        if isColorPicking {
            updateColorSample(at: global)
            copySampledColor()
            return
        }
        if selectionLocked {
            handleAnnotateMouseDown(at: global)
            return
        }
        hideToolbar()
        let hit = windows.hit(at: global)
        drag.mouseDown(at: global, windowBounds: hit?.logicalBounds)
        selection = nil
        hoverWindow = hit
        syncLayers()
    }

    fileprivate func mouseDragged(at global: CGPoint) {
        if isScrollCapturing || isOCRSelecting || isColorPicking { return }
        if selectionLocked {
            handleAnnotateMouseDragged(at: global)
            return
        }
        guard let rect = drag.mouseDragged(at: global) else { return }
        hoverWindow = nil
        selection = geometry.clampToSingleScreen(rect)
        syncLayers()
    }

    fileprivate func mouseUp(at global: CGPoint) {
        if isScrollCapturing || isOCRSelecting || isColorPicking { return }
        if selectionLocked {
            handleAnnotateMouseUp(at: global)
            return
        }
        switch drag.mouseUp(at: global) {
        case .region(let rect):
            selection = geometry.clampToSingleScreen(rect)
            hoverWindow = nil
            syncLayers()
            if selection != nil { finishSelection() }
        case .window(let bounds):
            selection = geometry.clampToSingleScreen(bounds)
            hoverWindow = nil
            syncLayers()
            if selection != nil { finishSelection() }
        case .none:
            selection = nil
            syncLayers()
        }
    }

    fileprivate func mouseMoved(at global: CGPoint) {
        updateCursor(at: global)
        let now = Date()
        guard now.timeIntervalSince(lastHoverSample) >= hoverInterval else { return }
        lastHoverSample = now
        if isColorPicking {
            updateMagnifier(at: global)
            updateColorSample(at: global)
            return
        }
        hideMagnifier()
        guard !selectionLocked, drag.dragStart == nil else { return }
        let hit = windows.hit(at: global)
        if hit?.windowID != hoverWindow?.windowID || hit?.logicalBounds != hoverWindow?.logicalBounds {
            hoverWindow = hit
            syncLayers()
        }
    }

    fileprivate func updateCursor(at global: CGPoint) {
        if isColorPicking {
            NSCursor.crosshair.set()
            return
        }
        if isOCRSelecting {
            if let sel = selection, sel.logicalRect.contains(global) {
                NSCursor.iBeam.set()
            } else {
                NSCursor.arrow.set()
            }
            return
        }
        if draggingTextID != nil {
            NSCursor.closedHand.set()
            return
        }
        if let handle = resizeHandle {
            SelectionResize.cursor(for: handle).set()
            return
        }
        if moveGrabStart != nil {
            NSCursor.closedHand.set()
            return
        }
        if selectionLocked, !isScrollCapturing, activeTool == nil, let sel = selection {
            if let handle = SelectionResize.hitTest(point: global, rect: sel.logicalRect) {
                SelectionResize.cursor(for: handle).set()
                return
            }
            if sel.logicalRect.contains(global) {
                NSCursor.openHand.set()
                return
            }
            NSCursor.arrow.set()
            return
        }
        guard selectionLocked, activeTool == .text, let sel = selection, sel.logicalRect.contains(global) else {
            if !selectionLocked {
                NSCursor.crosshair.set()
            } else {
                NSCursor.arrow.set()
            }
            return
        }
        let local = toSelectionLocal(global)
        if hitTextShape(at: local) != nil {
            NSCursor.openHand.set()
        } else {
            // 文字工具空白处：I 型光标，提示可输入
            NSCursor.iBeam.set()
        }
    }

    fileprivate func mouseDoubleClick(at global: CGPoint) {
        guard selectionLocked, let sel = selection, sel.logicalRect.contains(global) else { return }
        commitCopy()
    }

    private func finishSelection() {
        if autoCopyOnSelect {
            commitCopy()
            return
        }
        if autoSaveOnSelect {
            commitQuickSave()
            return
        }
        selectionLocked = true
        hideMagnifier()
        if enterScrollAfterSelect {
            enterScrollAfterSelect = false
            startScrollCapture()
            return
        }
        showToolbar()
        syncLayers()
    }

    // MARK: - Annotate

    private func handleAnnotateMouseDown(at global: CGPoint) {
        // 边缘 / 四角：拖拽调整选区（无标注工具时）
        if !isScrollCapturing,
           activeTool == nil,
           !isColorPicking,
           !isOCRSelecting,
           let sel = selection,
           let handle = SelectionResize.hitTest(point: global, rect: sel.logicalRect) {
            resizeHandle = handle
            resizeGrabStart = global
            resizeOriginRect = sel.logicalRect
            resizeStartShapes = annotations.document.shapes
            moveGrabStart = nil
            moveOriginRect = nil
            SelectionResize.cursor(for: handle).set()
            return
        }

        guard let sel = selection, sel.logicalRect.contains(global) else {
            // 浮动长截结果：点在图外直接关闭
            if isFloatingResult {
                cancel()
                return
            }
            // 点在选区外：重新框选
            selectionLocked = false
            annotations.reset()
            hideToolbar()
            let hit = windows.hit(at: global)
            drag.mouseDown(at: global, windowBounds: hit?.logicalBounds)
            selection = nil
            hoverWindow = hit
            draftShape = nil
            moveGrabStart = nil
            moveOriginRect = nil
            clearResizeSession()
            syncLayers()
            return
        }
        // 未选标注工具时：拖动移动选区 / 浮动结果窗
        if activeTool == nil {
            moveGrabStart = global
            moveOriginRect = sel.logicalRect
            NSCursor.closedHand.set()
            return
        }

        let local = toSelectionLocal(global)

        // 文字工具：点中已有文字 → 拖动或再次编辑
        if activeTool == .text, let hit = hitTextShape(at: local) {
            draggingTextID = hit.id
            dragTextStart = local
            dragTextOrigin = hit.points.first
            editingShapeID = hit.id
            textDragCheckpointed = false
            annotateStart = nil
            NSCursor.closedHand.set()
            return
        }

        annotateStart = local
        if activeTool == .text {
            editingShapeID = nil
            promptText(at: local, existing: nil)
            return
        }
        guard let kind = currentShapeKind() else { return }
        draftShape = makeDraftShape(kind: kind, at: local)
        syncLayers()
    }

    private func handleAnnotateMouseDragged(at global: CGPoint) {
        if let id = draggingTextID, let start = dragTextStart, let origin = dragTextOrigin {
            let local = toSelectionLocal(global)
            let dx = local.x - start.x
            let dy = local.y - start.y
            if abs(dx) > 1 || abs(dy) > 1 {
                if !textDragCheckpointed {
                    annotations.prepareUndoCheckpoint()
                    textDragCheckpointed = true
                }
                if var shape = annotations.document.shapes.first(where: { $0.id == id }) {
                    shape.points = [CGPoint(x: origin.x + dx, y: origin.y + dy)]
                    annotations.setShapeLive(shape)
                    syncLayers()
                }
                NSCursor.closedHand.set()
            }
            return
        }
        if let handle = resizeHandle,
           let grab = resizeGrabStart,
           let origin = resizeOriginRect,
           let sel = selection,
           let screen = geometry.screen(id: sel.screenID) {
            let translation = CGVector(dx: global.x - grab.x, dy: global.y - grab.y)
            let rect = SelectionResize.resizedRect(
                from: origin,
                handle: handle,
                translation: translation,
                bounds: screen.logicalFrame
            )
            guard rect.width >= SelectionResize.minSize.width,
                  rect.height >= SelectionResize.minSize.height else { return }
            selection = CaptureSelection(screenID: sel.screenID, logicalRect: rect)
            let shift = CGPoint(x: origin.minX - rect.minX, y: origin.minY - rect.minY)
            if !resizeStartShapes.isEmpty, (shift.x != 0 || shift.y != 0) {
                let shifted = resizeStartShapes.map { shape -> Shape in
                    var copy = shape
                    copy.points = shape.points.map {
                        CGPoint(x: $0.x + shift.x, y: $0.y + shift.y)
                    }
                    return copy
                }
                annotations.replaceShapesLive(shifted)
            } else if !resizeStartShapes.isEmpty {
                annotations.replaceShapesLive(resizeStartShapes)
            }
            applySelectionFrameToFloatingPanel(rect)
            repositionToolbar()
            SelectionResize.cursor(for: handle).set()
            syncLayers()
            return
        }
        if let grab = moveGrabStart, let origin = moveOriginRect, activeTool == nil {
            let dx = global.x - grab.x
            let dy = global.y - grab.y
            let moved = origin.offsetBy(dx: dx, dy: dy)
            if let next = geometry.clampToSingleScreen(moved) {
                // 保持原尺寸，仅平移（clamp 可能裁切时尽量贴边）
                var rect = CGRect(origin: next.logicalRect.origin, size: origin.size)
                if let screen = geometry.screen(id: next.screenID) {
                    rect.origin.x = min(max(rect.origin.x, screen.logicalFrame.minX),
                                        screen.logicalFrame.maxX - rect.width)
                    rect.origin.y = min(max(rect.origin.y, screen.logicalFrame.minY),
                                        screen.logicalFrame.maxY - rect.height)
                    selection = CaptureSelection(screenID: next.screenID, logicalRect: rect)
                } else {
                    selection = next
                }
                applySelectionFrameToFloatingPanel(selection?.logicalRect ?? rect)
                repositionToolbar()
                syncLayers()
            }
            return
        }
        guard var draft = draftShape, let start = annotateStart, activeTool != nil else { return }
        let local = toSelectionLocal(global)
        if isStrokeKind(draft.kind) {
            draft.points.append(local)
        } else {
            draft.points = [start, local]
        }
        draftShape = draft
        syncLayers()
    }

    private func applySelectionFrameToFloatingPanel(_ rect: CGRect) {
        guard isFloatingResult, let panel = panels.first else { return }
        panel.setFrame(rect, display: true)
        if var frame = frames.first {
            frame.logicalBounds = rect
            frames = [frame]
            (panel.contentView as? OverlayView)?.screenFrame = frame
        }
    }

    private func handleAnnotateMouseUp(at global: CGPoint) {
        if let id = draggingTextID {
            let local = toSelectionLocal(global)
            let moved = textDragCheckpointed
            draggingTextID = nil
            dragTextStart = nil
            dragTextOrigin = nil
            textDragCheckpointed = false
            if !moved, let shape = annotations.document.shapes.first(where: { $0.id == id }) {
                promptText(at: shape.points.first ?? local, existing: shape)
            } else {
                updateCursor(at: global)
            }
            return
        }
        if moveGrabStart != nil {
            moveGrabStart = nil
            moveOriginRect = nil
            showToolbar()
            updateCursor(at: global)
            return
        }
        if resizeHandle != nil {
            clearResizeSession()
            showToolbar()
            updateCursor(at: global)
            return
        }
        guard var draft = draftShape else {
            annotateStart = nil
            return
        }
        let local = toSelectionLocal(global)
        if isStrokeKind(draft.kind) {
            draft.points.append(local)
        } else if let start = annotateStart {
            draft.points = [start, local]
        }
        if !isStrokeKind(draft.kind) {
            let pts = draft.points
            if pts.count >= 2 {
                let dx = abs(pts[0].x - pts[1].x)
                let dy = abs(pts[0].y - pts[1].y)
                if dx < 2, dy < 2 {
                    draftShape = nil
                    annotateStart = nil
                    syncLayers()
                    return
                }
            }
        }
        annotations.add(draft)
        draftShape = nil
        annotateStart = nil
        syncLayers()
    }

    private func isStrokeKind(_ kind: ShapeKind) -> Bool {
        kind == .freehand || kind == .marker || kind == .eraser
    }

    private func makeDraftShape(kind: ShapeKind, at local: CGPoint) -> Shape {
        switch kind {
        case .marker:
            return Shape(
                kind: .marker,
                lineWidth: 14,
                points: [local],
                color: NSColor.systemYellow.withAlphaComponent(0.45)
            )
        case .eraser:
            return Shape(kind: .eraser, lineWidth: 18, points: [local], color: .black)
        case .freehand:
            return Shape(kind: .freehand, lineWidth: 3, points: [local])
        default:
            return Shape(kind: kind, lineWidth: 2, points: [local])
        }
    }

    private func hitTextShape(at local: CGPoint) -> Shape? {
        for shape in annotations.document.shapes.reversed() where shape.kind == .text {
            let rect = AnnotationController.textFrame(shape).insetBy(dx: -6, dy: -6)
            if rect.contains(local) { return shape }
        }
        return nil
    }

    private func promptText(at local: CGPoint, existing: Shape?) {
        closeTextEditor(commit: false)
        guard let sel = selection else { return }
        pendingTextLocal = local
        editingShapeID = existing?.id
        isEditingText = true

        for panel in panels {
            guard let view = panel.contentView as? OverlayView,
                  view.screenFrame?.screenID == sel.screenID
            else { continue }
            panel.makeKeyAndOrderFront(nil)
            view.beginTextInput(
                selectionLocal: local,
                selectionGlobal: sel.logicalRect,
                fontSize: existing?.lineWidth ?? textFontSize,
                color: existing?.nsColor ?? textColor,
                initial: existing?.text ?? "",
                onCommit: { [weak self] text in self?.finishTextInput(text) },
                onCancel: { [weak self] in self?.closeTextEditor(commit: false); self?.syncLayers() }
            )
            textHostView = view
            annotateStart = nil
            // 编辑时隐藏原文，避免叠字
            syncLayersHidingText(editingShapeID)
            return
        }
        isEditingText = false
        pendingTextLocal = nil
        editingShapeID = nil
    }

    private func finishTextInput(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 成稿锚点：按「编辑顶边 = 成稿顶边」反推字框原点（消除 firstRect 与 textSize 行高差）
        let point = textHostView?.textDrawOriginInSelectionLocal(
            selectionGlobal: selection?.logicalRect ?? .zero,
            text: trimmed,
            fontSize: textFontSize
        ) ?? pendingTextLocal
        let editID = editingShapeID
        closeTextEditor(commit: false)
        guard let point else {
            syncLayers()
            return
        }
        if trimmed.isEmpty {
            if let editID { annotations.remove(id: editID) }
            syncLayers()
            return
        }
        if let editID, var shape = annotations.document.shapes.first(where: { $0.id == editID }) {
            shape.text = trimmed
            shape.points = [point]
            shape.lineWidth = textFontSize
            annotations.replace(shape)
        } else {
            annotations.add(Shape(
                kind: .text,
                lineWidth: textFontSize,
                points: [point],
                text: trimmed,
                color: textColor
            ))
        }
        syncLayers()
    }

    private func closeTextEditor(commit: Bool) {
        textHostView?.endTextInput()
        textHostView = nil
        isEditingText = false
        pendingTextLocal = nil
        annotateStart = nil
        editingShapeID = nil
    }

    /// 再编辑时隐藏原文，避免与输入框叠字
    private func syncLayersHidingText(_ hideID: UUID?) {
        for panel in panels {
            (panel.contentView as? OverlayView)?.apply(
                selection: selection,
                hover: selectionLocked || isScrollCapturing ? nil : hoverWindow,
                shapes: annotations.document.shapes.filter { $0.id != hideID },
                draft: draftShape,
                locked: selectionLocked,
                scrollCapturing: isScrollCapturing,
                scrollPreview: isScrollCapturing ? scrollPreviewCanvas : nil
            )
        }
    }

    private func toSelectionLocal(_ global: CGPoint) -> CGPoint {
        guard let sel = selection else { return global }
        return CGPoint(x: global.x - sel.logicalRect.minX, y: global.y - sel.logicalRect.minY)
    }

    // MARK: - Toolbar delegate

    private func currentShapeKind() -> ShapeKind? {
        switch activeTool {
        case .shape:
            return shapeStyle == .ellipse ? .ellipse : .rect
        case .arrow:
            return arrowStyle == .line ? .line : .arrow
        case .pen:
            switch penStyle {
            case .pen: return .freehand
            case .marker: return .marker
            case .eraser: return .eraser
            }
        case .mosaic:
            return mosaicStyle == .blur ? .blur : .mosaic
        case .text: return .text
        case .none: return nil
        }
    }

    func toolbarSelectTool(_ tool: CaptureAnnotateTool?) {
        exitOCRMode()
        exitColorPick()
        closeTextEditor(commit: false)
        activeTool = tool
        if let sel = selection {
            updateCursor(at: CGPoint(x: sel.logicalRect.midX, y: sel.logicalRect.midY))
        } else {
            NSCursor.arrow.set()
        }
    }

    func toolbarSelectShapeStyle(_ style: CaptureShapeStyle) {
        exitColorPick()
        shapeStyle = style
        activeTool = .shape
    }

    func toolbarSelectArrowStyle(_ style: CaptureArrowStyle) {
        exitColorPick()
        arrowStyle = style
        activeTool = .arrow
    }

    func toolbarSelectMosaicStyle(_ style: CaptureMosaicStyle) {
        exitColorPick()
        mosaicStyle = style
        activeTool = .mosaic
    }

    func toolbarSelectPenStyle(_ style: CapturePenStyle) {
        exitColorPick()
        penStyle = style
        activeTool = .pen
    }

    func toolbarToggleEyedropper() {
        if isColorPicking {
            exitColorPick()
        } else {
            enterColorPick()
        }
    }

    private func enterColorPick() {
        exitOCRMode()
        closeTextEditor(commit: false)
        activeTool = nil
        draftShape = nil
        isColorPicking = true
        toolbar?.setSelectedTool(nil)
        toolbar?.setEyedropperOn(true)
        if colorHUD == nil { colorHUD = ColorSampleHUD() }
        NSCursor.crosshair.set()
        let loc = NSEvent.mouseLocation
        updateMagnifier(at: loc)
        updateColorSample(at: loc)
        syncLayers()
    }

    private func exitColorPick(updateToolbar: Bool = true) {
        guard isColorPicking || colorHUD != nil else { return }
        isColorPicking = false
        lastSampledColor = nil
        colorHUD?.hide()
        colorHUD = nil
        if updateToolbar {
            toolbar?.setEyedropperOn(false)
        }
        if selectionLocked {
            hideMagnifier()
        }
    }

    private func updateColorSample(at global: CGPoint) {
        guard let color = ColorSampler.sample(at: global, in: frames) else {
            colorHUD?.hide()
            return
        }
        lastSampledColor = color
        if colorHUD == nil { colorHUD = ColorSampleHUD() }
        colorHUD?.show(color: color, near: global)
    }

    private func copySampledColor() {
        if let text = colorHUD?.copyActive() {
            PinSnapLog.app.info("color copied: \(text, privacy: .public)")
            return
        }
        guard let color = lastSampledColor else { return }
        let text = ColorValueFormat.current.string(for: color)
        ColorSampler.copyToPasteboard(text)
        PinSnapLog.app.info("color copied: \(text, privacy: .public)")
    }

    private func updateMagnifier(at global: CGPoint) {
        // 仅取色模式展示放大镜
        guard isColorPicking else {
            hideMagnifier()
            return
        }
        guard let patch = ColorSampler.magnifierPatch(at: global, in: frames)?.image else {
            hideMagnifier()
            return
        }
        if magnifierHUD == nil { magnifierHUD = MagnifierHUD() }
        magnifierHUD?.show(patch: patch, near: global)
    }

    private func hideMagnifier() {
        magnifierHUD?.hide()
        magnifierHUD = nil
    }

    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let sel = selection else { return }
        var rect = sel.logicalRect.offsetBy(dx: dx, dy: dy)
        guard let screen = geometry.screen(id: sel.screenID) else { return }
        rect.origin.x = min(max(rect.origin.x, screen.logicalFrame.minX),
                            screen.logicalFrame.maxX - rect.width)
        rect.origin.y = min(max(rect.origin.y, screen.logicalFrame.minY),
                            screen.logicalFrame.maxY - rect.height)
        selection = CaptureSelection(screenID: sel.screenID, logicalRect: rect)
        repositionToolbar()
        syncLayers()
    }

    func toolbarUndo() {
        exitOCRMode()
        closeTextEditor(commit: false)
        annotations.undo()
        draftShape = nil
        syncLayers()
    }

    func toolbarRedo() {
        exitOCRMode()
        closeTextEditor(commit: false)
        annotations.redo()
        draftShape = nil
        syncLayers()
    }

    func toolbarOCR() { beginOCR() }
    func toolbarCopy() {
        if isOCRSelecting, copyOCRSelection() { return }
        commitCopy()
    }
    func toolbarSave() { commitSave() }
    func toolbarPin() { commitPin() }
    func toolbarClose() {
        if isScrollCapturing {
            stopScrollCapture(commit: false)
            cancel()
            return
        }
        cancel()
    }
    func toolbarScrollCapture() {
        if isFloatingResult { return }
        // 长截中再点一次 = 完成
        if isScrollCapturing {
            stopScrollCapture(commit: true)
            return
        }
        startScrollCapture()
    }

    // MARK: - Scroll capture (long screenshot)
    // 完全对齐 iShot MXClipView（r2 核验）：
    // 100ms 首帧；deltaY<0 立刻截 + 重置 60ms；Δ≥0 忽略；idle 只补截不退出；
    // 帧数组+SAD+10px blend；自动滚 CGEvent(line) 注入；显式完成才导出。

    private static let scrollFirstFrameDelayNs: UInt64 = 100_000_000
    private static let scrollSettleInterval: TimeInterval = 0.06
    private static let scrollDeltaNoise: CGFloat = 0.5
    private static let scrollAutoInterval: TimeInterval = 0.12
    private static let scrollAutoWheelLines: Int32 = 3

    private enum ScrollCaptureTrigger {
        case firstFrame
        case wheel
        case settle
    }

    private func startScrollCapture() {
        guard !isScrollCapturing,
              selectionLocked,
              let selection,
              captureRegion != nil
        else {
            PinSnapLog.capture.error("startScrollCapture aborted: locked=\(self.selectionLocked) hasCapture=\(self.captureRegion != nil)")
            return
        }

        exitOCRMode()
        closeTextEditor(commit: false)
        exitColorPick(updateToolbar: false)
        hideMagnifier()
        activeTool = nil
        draftShape = nil

        scrollPreviewCanvas = nil
        scrollStitchSession = nil
        scrollCaptureBusy = false
        scrollNeedsRecapture = false
        stopAutoScroll()
        invalidateScrollIdleTimer()
        removeScrollWheelMonitor()
        removeScrollGlobalEndMonitors()

        isScrollCapturing = true
        onScrollCaptureActiveChange?(true)

        for panel in panels {
            panel.ignoresMouseEvents = true
        }
        syncLayers()
        toolbar?.orderOut(nil)
        installScrollWheelMonitor()
        installScrollGlobalEndMonitors()
        presentScrollSidePreview(beside: selection)
        presentScrollDoneBar(beside: selection)

        PinSnapLog.capture.info(
            "scroll start rect=\(Int(selection.logicalRect.width))x\(Int(selection.logicalRect.height)) ishot"
        )

        scrollTask?.cancel()
        scrollTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.scrollFirstFrameDelayNs)
            guard !Task.isCancelled, self.isScrollCapturing else { return }
            await self.captureScrollFrame(trigger: .firstFrame)
        }
    }

    private func installScrollWheelMonitor() {
        removeScrollWheelMonitor()
        scrollWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            Task { @MainActor in
                self?.handleScrollWheelForCapture(event)
            }
        }
        if scrollWheelMonitor == nil {
            PinSnapLog.capture.error("scroll wheel global monitor unavailable")
        }
    }

    private func removeScrollWheelMonitor() {
        if let monitor = scrollWheelMonitor {
            NSEvent.removeMonitor(monitor)
            scrollWheelMonitor = nil
        }
    }

    private func installScrollGlobalEndMonitors() {
        removeScrollGlobalEndMonitors()
        scrollGlobalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self, self.isScrollCapturing else { return }
                if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 {
                    self.stopScrollCapture(commit: self.scrollStitchSession != nil)
                }
            }
        }
        scrollGlobalRightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isScrollCapturing else { return }
                self.stopScrollCapture(commit: self.scrollStitchSession != nil)
            }
        }
    }

    private func removeScrollGlobalEndMonitors() {
        if let scrollGlobalKeyMonitor {
            NSEvent.removeMonitor(scrollGlobalKeyMonitor)
            self.scrollGlobalKeyMonitor = nil
        }
        if let scrollGlobalRightClickMonitor {
            NSEvent.removeMonitor(scrollGlobalRightClickMonitor)
            self.scrollGlobalRightClickMonitor = nil
        }
    }

    private func invalidateScrollIdleTimer() {
        scrollIdleTimer?.invalidate()
        scrollIdleTimer = nil
    }

    private func resetScrollIdleTimer() {
        invalidateScrollIdleTimer()
        let timer = Timer(timeInterval: Self.scrollSettleInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.handleScrollSettleTimeout()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollIdleTimer = timer
    }

    private func handleScrollSettleTimeout() async {
        guard isScrollCapturing else { return }
        await captureScrollFrame(trigger: .settle)
    }

    private func handleScrollWheelForCapture(_ event: NSEvent) {
        guard isScrollCapturing else { return }
        let deltaY = event.scrollingDeltaY
        guard abs(deltaY) > Self.scrollDeltaNoise else { return }
        guard deltaY < 0 else { return }

        resetScrollIdleTimer()
        if scrollCaptureBusy {
            scrollNeedsRecapture = true
            return
        }
        Task { @MainActor in
            await self.captureScrollFrame(trigger: .wheel)
        }
    }

    private func captureScrollFrame(trigger: ScrollCaptureTrigger) async {
        guard isScrollCapturing, !scrollCaptureBusy else {
            if isScrollCapturing { scrollNeedsRecapture = true }
            return
        }

        scrollCaptureBusy = true
        defer {
            scrollCaptureBusy = false
            if isScrollCapturing, scrollNeedsRecapture {
                scrollNeedsRecapture = false
                Task { @MainActor in
                    await self.captureScrollFrame(trigger: .wheel)
                }
            }
        }

        guard let selection, let capture = captureRegion else { return }

        // 高度触顶才自动完成；帧数只作安全阀（已放宽），避免中途误停
        if let session = scrollStitchSession,
           session.canvas.height >= StitchCanvas.maxOutputHeight {
            stopScrollCapture(commit: true)
            return
        }

        let exclude = scrollExcludeWindowIDs()
        do {
            let image = try await capture(selection, exclude)
            if scrollStitchSession == nil {
                let session = ScrollStitchSession(firstFrame: image)
                scrollStitchSession = session
                scrollPreviewCanvas = session.makePreviewImage()
                scrollSidePreview?.update(preview: scrollPreviewCanvas)
                syncLayers()
                PinSnapLog.capture.info("scroll seed \(image.width)x\(image.height)")
            } else {
                await ingestScrollFrame(image)
            }
        } catch {
            PinSnapLog.capture.error("scroll capture frame: \(error.localizedDescription)")
        }
    }

    private func ingestScrollFrame(_ image: CGImage) async {
        guard let session = scrollStitchSession else { return }
        let result = await Task.detached(priority: .userInitiated) {
            session.append(image)
        }.value

        if result.didChange {
            scrollPreviewCanvas = result.preview
            scrollSidePreview?.update(preview: result.preview)
            syncLayers()
            refreshScrollSidePreviewAvoidance()
            PinSnapLog.capture.info(
                "scroll advance=\(result.totalAdvance) frames=\(session.frameCount) canvasH=\(session.canvas.height)"
            )
        }
        if result.hitLimit {
            stopScrollCapture(commit: true)
        }
    }

    private func scrollExcludeWindowIDs() -> [CGWindowID] {
        var ids: [CGWindowID] = []
        for panel in panels {
            ids.append(CGWindowID(panel.windowNumber))
        }
        if let toolbar {
            ids.append(CGWindowID(toolbar.windowNumber))
        }
        if let preview = scrollSidePreview {
            ids.append(CGWindowID(preview.windowNumber))
        }
        if let done = scrollDoneBar {
            ids.append(CGWindowID(done.windowNumber))
        }
        return ids
    }

    private func presentScrollSidePreview(beside selection: CaptureSelection) {
        dismissScrollSidePreview()
        let preview = ScrollCapturePreview()
        if let screen = geometry.screen(id: selection.screenID) {
            preview.place(
                beside: selection.logicalRect,
                inScreenBounds: screen.logicalFrame,
                avoiding: nil
            )
        }
        preview.update(preview: scrollPreviewCanvas)
        scrollSidePreview = preview
    }

    private func presentScrollDoneBar(beside selection: CaptureSelection) {
        dismissScrollDoneBar()
        let bar = ScrollCaptureDoneBar()
        bar.onDone = { [weak self] in
            self?.stopScrollCapture(commit: true)
        }
        bar.onCancel = { [weak self] in
            self?.stopScrollCapture(commit: false)
            self?.cancel()
        }
        bar.onToggleAutoScroll = { [weak self] in
            self?.toggleAutoScroll()
        }
        bar.setAutoScrolling(false)
        if let screen = geometry.screen(id: selection.screenID) {
            bar.place(near: selection.logicalRect, inScreenBounds: screen.logicalFrame)
        }
        scrollDoneBar = bar
    }

    private func toggleAutoScroll() {
        if isAutoScrolling { stopAutoScroll() } else { startAutoScroll() }
    }

    private func startAutoScroll() {
        guard isScrollCapturing else { return }
        stopAutoScroll()
        isAutoScrolling = true
        scrollDoneBar?.setAutoScrolling(true)
        if let selection {
            let mid = CGPoint(x: selection.logicalRect.midX, y: selection.logicalRect.midY)
            let cgRect = ScreenGeometry.cocoaToCGWindowRect(
                CGRect(x: mid.x, y: mid.y, width: 1, height: 1)
            )
            let move = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: cgRect.midX, y: cgRect.midY),
                mouseButton: .left
            )
            move?.post(tap: CGEventTapLocation.cghidEventTap)
        }
        let timer = Timer(timeInterval: Self.scrollAutoInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.postAutoScrollWheel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollAutoTimer = timer
        postAutoScrollWheel()
    }

    private func stopAutoScroll() {
        scrollAutoTimer?.invalidate()
        scrollAutoTimer = nil
        isAutoScrolling = false
        scrollDoneBar?.setAutoScrolling(false)
    }

    private func postAutoScrollWheel() {
        guard isScrollCapturing, isAutoScrolling else { return }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: -Self.scrollAutoWheelLines,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }

    private func refreshScrollSidePreviewAvoidance() {
        scrollSidePreview?.setAvoiding(nil)
    }

    private func dismissScrollSidePreview() {
        scrollSidePreview?.orderOut(nil)
        scrollSidePreview?.close()
        scrollSidePreview = nil
    }

    private func dismissScrollDoneBar() {
        scrollDoneBar?.orderOut(nil)
        scrollDoneBar?.close()
        scrollDoneBar = nil
    }

    private func stopScrollCapture(commit: Bool) {
        scrollTask?.cancel()
        scrollTask = nil
        stopAutoScroll()
        invalidateScrollIdleTimer()
        removeScrollWheelMonitor()
        removeScrollGlobalEndMonitors()
        dismissScrollSidePreview()
        dismissScrollDoneBar()

        guard isScrollCapturing else { return }

        let session = scrollStitchSession
        scrollPreviewCanvas = nil
        scrollStitchSession = nil
        scrollCaptureBusy = false
        scrollNeedsRecapture = false

        isScrollCapturing = false
        onScrollCaptureActiveChange?(false)

        if commit {
            for panel in panels {
                panel.orderOut(nil)
                panel.close()
            }
            panels = []
            toolbar?.orderOut(nil)
            toolbar?.close()
            toolbar = nil

            let stitched = session?.makeFullImage()
            PinSnapLog.capture.info(
                "scroll done accepted=\(session?.acceptedCount ?? 0) canvasH=\(session?.canvas.height ?? 0) size=\(stitched?.width ?? 0)x\(stitched?.height ?? 0)"
            )

            guard let stitched,
                  let selection,
                  let screen = geometry.screen(id: selection.screenID)
            else {
                PinSnapLog.capture.error("scroll stitch failed")
                ScrollStitcher.clearGrayCache()
                cancel()
                return
            }
            presentStitchedResult(stitched, on: screen, anchor: selection)
            return
        }

        ScrollStitcher.clearGrayCache()
        for panel in panels {
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
        }
        syncLayers()
        if selectionLocked { showToolbar() }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentStitchedResult(_ image: CGImage, on screen: ScreenDescriptor, anchor: CaptureSelection) {
        annotations.reset()
        draftShape = nil
        floatingFullImage = image
        isFloatingResult = true

        let scale = screen.scale
        let fullW = CGFloat(image.width) / scale
        let fullH = CGFloat(image.height) / scale
        let maxW = min(screen.logicalFrame.width * 0.42, 480)
        let maxH = min(screen.logicalFrame.height * 0.58, 620)
        let fit = min(1, maxW / max(fullW, 1), maxH / max(fullH, 1))
        let logicalW = max(120, fullW * fit)
        let logicalH = max(120, fullH * fit)

        var rect = CGRect(
            x: anchor.logicalRect.midX - logicalW / 2,
            y: anchor.logicalRect.midY - logicalH / 2,
            width: logicalW,
            height: logicalH
        )
        let screenFrame = screen.logicalFrame
        let toolbarReserve: CGFloat = 56
        rect.origin.x = min(max(rect.minX, screenFrame.minX + 16), screenFrame.maxX - logicalW - 16)
        rect.origin.y = min(
            max(rect.minY, screenFrame.minY + toolbarReserve + 16),
            screenFrame.maxY - logicalH - 16
        )

        let displayPixelsW = max(1, Int((logicalW * scale).rounded()))
        let displayPixelsH = max(1, Int((logicalH * scale).rounded()))
        let displayImage = Self.rescaleImage(
            image,
            toSize: CGSize(width: displayPixelsW, height: displayPixelsH)
        ) ?? image

        let newFrame = ScreenFrame(
            screenID: screen.id,
            logicalBounds: rect,
            scale: scale,
            image: displayImage
        )
        frames = [newFrame]
        selection = CaptureSelection(screenID: screen.id, logicalRect: rect)
        selectionLocked = true

        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()

        let panel = OverlayPanel(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // 低于工具条，避免挡住关闭按钮
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        let view = OverlayView(frame: NSRect(origin: .zero, size: rect.size))
        view.screenFrame = newFrame
        view.controller = self
        view.floatingResult = true
        view.installLayers()
        panel.contentView = view
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
        panels.append(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)

        showToolbar()
        toolbar?.level = .floating + 1
        toolbar?.orderFrontRegardless()
        installFloatingEscMonitor()
        syncLayers()
    }

    private static func rescaleImage(_ image: CGImage, toSize size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - OCR

    private func beginOCR() {
        guard selectionLocked, let sel = selection else {
            PinSnapLog.app.error("OCR: selection not locked")
            return
        }
        closeTextEditor(commit: false)
        activeTool = nil
        toolbar?.setSelectedTool(nil)
        draftShape = nil
        syncLayers()
        dismissCodeResultBar()
        ocrHostView?.removeOCR()
        ocrHostView = nil
        isOCRSelecting = false

        guard let image = exportImage(),
              let frame = frames.first(where: { $0.screenID == sel.screenID })
        else {
            PinSnapLog.app.error("OCR: exportImage failed")
            return
        }

        let scale = frame.scale
        PinSnapLog.app.info("OCR: start \(image.width)x\(image.height) scale=\(scale)")
        ocrTask?.cancel()
        ocrTask = Task { [weak self] in
            do {
                // 有码优先
                let codes = try await OCRService.recognizeBarcodes(in: image)
                if let payload = codes.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    guard let self, !Task.isCancelled else { return }
                    await MainActor.run {
                        self.finishBarcode(payload)
                    }
                    return
                }
                let result = try await OCRService.recognizeLines(in: image)
                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    self.finishOCR(result, image: image, scale: scale)
                }
            } catch {
                guard !Task.isCancelled else { return }
                PinSnapLog.app.error("OCR failed: \(error.localizedDescription)")
            }
        }
    }

    private func finishBarcode(_ payload: String) {
        guard let sel = selection else { return }
        dismissCodeResultBar()
        isOCRSelecting = true
        let bar = OCRCodeResultBar(payload: payload, under: sel.logicalRect) { [weak self] in
            self?.exitOCRMode()
        }
        codeResultBar = bar
        bar.present()
        PinSnapLog.app.info("OCR: barcode payload len=\(payload.count)")
    }

    private func finishOCR(_ result: OCRResult, image: CGImage, scale: CGFloat) {
        guard let sel = selection else { return }
        ocrHostView?.removeOCR()
        ocrHostView = nil
        guard !result.isEmpty else {
            PinSnapLog.app.info("OCR: no text recognized")
            return
        }
        PinSnapLog.app.info("OCR: \(result.lines.count) lines")
        for panel in panels {
            guard let view = panel.contentView as? OverlayView,
                  view.screenFrame?.screenID == sel.screenID
            else { continue }
            view.installOCR(
                lines: result.lines,
                selectionGlobal: sel.logicalRect,
                imagePixelSize: CGSize(width: image.width, height: image.height),
                scale: scale
            )
            ocrHostView = view
            panel.makeKeyAndOrderFront(nil)
            view.window?.makeFirstResponder(view.ocrOverlayForFocus)
            break
        }
        isOCRSelecting = true
        updateCursor(at: CGPoint(x: sel.logicalRect.midX, y: sel.logicalRect.midY))
    }

    private func exitOCRMode() {
        ocrTask?.cancel()
        ocrTask = nil
        dismissCodeResultBar()
        ocrHostView?.removeOCR()
        ocrHostView = nil
        isOCRSelecting = false
    }

    private func dismissCodeResultBar() {
        codeResultBar?.orderOut(nil)
        codeResultBar = nil
    }

    @discardableResult
    private func copyOCRSelection() -> Bool {
        let ok = ocrHostView?.copyOCRSelection() ?? false
        if ok {
            PinSnapLog.app.info("OCR: copied selection")
        } else {
            PinSnapLog.app.info("OCR: nothing selected to copy")
        }
        return ok
    }

    private func selectAllOCR() {
        ocrHostView?.selectAllOCR()
    }

    // MARK: - Commit

    fileprivate func cancel() {
        forceCloseFloatingChrome()
        dismiss()
        onFinish?(.cancelled)
    }

    /// 确保长截浮动窗 / 工具条被关掉（避免只 orderOut 失败留下残影）。
    private func forceCloseFloatingChrome() {
        toolbar?.orderOut(nil)
        toolbar?.close()
        toolbar = nil
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        isFloatingResult = false
        floatingFullImage = nil
    }

    fileprivate func commitCopy() {
        guard let image = exportImage(), let selection else { return }
        try? exporter.copyToClipboard(image)
        dismiss()
        onFinish?(.copied(image, selection: selection))
    }

    fileprivate func commitSave() {
        guard let image = exportImage() else {
            PinSnapLog.app.error("save: exportImage returned nil")
            return
        }
        let format = SavePreferences.saveFormat

        // 菜单栏 App + 全屏 screenSaver 遮罩时，NSSavePanel 常被挡住或无法成为 key。
        let overlayPanels = panels
        let bar = toolbar
        for panel in overlayPanels { panel.orderOut(nil) }
        bar?.orderOut(nil)

        let previousPolicy = NSApp.activationPolicy()
        if previousPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [SavePreferences.contentType(for: format)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = SavePreferences.suggestedFileName(
            width: image.width,
            height: image.height,
            format: format
        )
        if let dir = SavePreferences.resolveDirectory(.defaultSave) {
            panel.directoryURL = dir
        }
        panel.level = .modalPanel

        let result = panel.runModal()

        if previousPolicy != .regular {
            NSApp.setActivationPolicy(previousPolicy)
        }

        guard result == .OK, let url = panel.url else {
            for p in overlayPanels { p.orderFrontRegardless() }
            if selectionLocked {
                showToolbar()
            }
            return
        }

        do {
            guard let selection else {
                PinSnapLog.app.error("save: selection missing")
                for p in overlayPanels { p.orderFrontRegardless() }
                if selectionLocked { showToolbar() }
                return
            }
            if let dir = SavePreferences.resolveDirectory(.defaultSave),
               url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
                try SavePreferences.withSecurityScopedAccess(to: dir) {
                    try exporter.save(image, to: url, format: format)
                }
            } else {
                try exporter.save(image, to: url, format: format)
            }
            dismiss()
            onFinish?(.saved(image, selection: selection))
        } catch {
            PinSnapLog.app.error("save failed: \(error.localizedDescription)")
            for p in overlayPanels { p.orderFrontRegardless() }
            if selectionLocked {
                showToolbar()
            }
        }
    }

    /// ⌘S：写入快捷/默认目录；均未配置则回落保存面板。⌘⇧S 为另存为面板。
    fileprivate func commitQuickSave() {
        guard let image = exportImage(), let selection else {
            PinSnapLog.app.error("quickSave: exportImage/selection missing")
            return
        }
        guard let directory = SavePreferences.resolveQuickSaveDirectory() else {
            commitSave()
            return
        }
        let format = SavePreferences.saveFormat
        let url = SavePreferences.makeUniqueFileURL(
            in: directory,
            width: image.width,
            height: image.height,
            format: format
        )
        do {
            try SavePreferences.withSecurityScopedAccess(to: directory) {
                try exporter.save(image, to: url, format: format)
            }
            dismiss()
            onFinish?(.saved(image, selection: selection))
            Toast.shared.show("已保存")
        } catch {
            PinSnapLog.app.error("quickSave failed: \(error.localizedDescription)")
            commitSave()
        }
    }

    fileprivate func commitPin() {
        guard let image = exportImage(), let selection else { return }
        let frame = selection.logicalRect
        // 长图全分辨率贴图会卡死交互；贴图侧限制最长边
        let pinImage = Self.cappedImage(image, maxEdge: 4096)
        forceCloseFloatingChrome()
        dismiss()
        onFinish?(.pinned(pinImage, frame: frame, selection: selection))
    }

    private static func cappedImage(_ image: CGImage, maxEdge: Int) -> CGImage {
        let edge = max(image.width, image.height)
        guard edge > maxEdge, edge > 0 else { return image }
        let scale = CGFloat(maxEdge) / CGFloat(edge)
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))
        return rescaleImage(image, toSize: CGSize(width: w, height: h)) ?? image
    }

    private func exportImage() -> CGImage? {
        guard let selection,
              let frame = frames.first(where: { $0.screenID == selection.screenID })
        else { return nil }

        // 长截浮动结果：导出全分辨率原图 + 按显示逻辑坐标放大标注
        if isFloatingResult, let full = floatingFullImage {
            let pixelScale = CGFloat(full.width) / max(selection.logicalRect.width, 1)
            let scaled = annotationsScaledToPixels(scale: pixelScale)
            let ctrl = AnnotationController()
            for s in scaled.shapes { ctrl.add(s) }
            return ctrl.exportFlattened(base: full) ?? full
        }

        guard let base = exporter.crop(frame: frame, selection: selection, geometry: geometry) else {
            return nil
        }
        let scaled = annotationsScaledToPixels(scale: frame.scale)
        let ctrl = AnnotationController()
        for s in scaled.shapes { ctrl.add(s) }
        return ctrl.exportFlattened(base: base) ?? base
    }

    private func annotationsScaledToPixels(scale: CGFloat) -> AnnotationDocument {
        var doc = AnnotationDocument()
        let all = annotations.document.shapes + (draftShape.map { [$0] } ?? [])
        for shape in all {
            var s = shape
            s.points = shape.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
            s.lineWidth = shape.lineWidth * scale
            doc.shapes.append(s)
        }
        return doc
    }

    // MARK: - Toolbar / layers

    private func showToolbar() {
        guard selection != nil, !isScrollCapturing else { return }
        if toolbar == nil {
            let bar = CaptureToolbar()
            bar.actionHandler = self
            toolbar = bar
        }
        guard let toolbar else { return }
        toolbar.setShapeStyle(shapeStyle)
        toolbar.setArrowStyle(arrowStyle)
        toolbar.setMosaicStyle(mosaicStyle)
        toolbar.setPenStyle(penStyle)
        toolbar.setSelectedTool(activeTool)
        toolbar.setEyedropperOn(isColorPicking)
        repositionToolbar()
    }

    /// 只更新位置，不销毁重建（拖动选区时每帧重建会导致工具栏闪烁）。
    private func repositionToolbar() {
        guard let selection, let toolbar else { return }
        if let screen = geometry.screen(id: selection.screenID) {
            toolbar.place(under: selection.logicalRect, inScreenBounds: screen.logicalFrame, bringToFront: false)
        } else {
            toolbar.setFrameOrigin(NSPoint(
                x: selection.logicalRect.midX - toolbar.width / 2,
                y: selection.logicalRect.minY - toolbar.height - 12
            ))
        }
    }

    private func hideToolbar() {
        toolbar?.orderOut(nil)
        toolbar = nil
    }

    private func syncLayers() {
        for panel in panels {
            (panel.contentView as? OverlayView)?.apply(
                selection: selection,
                hover: selectionLocked || isScrollCapturing ? nil : hoverWindow,
                shapes: isScrollCapturing ? [] : annotations.document.shapes,
                draft: isScrollCapturing ? nil : draftShape,
                locked: selectionLocked,
                scrollCapturing: isScrollCapturing,
                scrollPreview: isScrollCapturing ? scrollPreviewCanvas : nil
            )
        }
    }

    fileprivate func keyDown(_ event: NSEvent) {
        if isScrollCapturing {
            if event.keyCode == 53 {
                stopScrollCapture(commit: scrollStitchSession != nil)
                return
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                stopScrollCapture(commit: true)
                return
            }
            return
        }
        if isOCRSelecting {
            if event.keyCode == 53 {
                exitOCRMode()
                return
            }
            if event.modifierFlags.contains(.command) {
                switch event.keyCode {
                case 8: // C
                    _ = copyOCRSelection()
                    return
                case 0: // A
                    selectAllOCR()
                    return
                default:
                    break
                }
            }
            return
        }
        switch event.keyCode {
        case 53: // Esc — 由 monitor 的 handleEscape 处理；保留兼容
            handleEscape()
        case 36, 76: commitCopy()
        case 8 where event.modifierFlags.contains(.command): commitCopy()
        case 1 where event.modifierFlags.contains(.command):
            if event.modifierFlags.contains(.shift) {
                commitSave()
            } else {
                commitQuickSave()
            }
        case 6 where event.modifierFlags.contains(.command):
            if event.modifierFlags.contains(.shift) {
                toolbarRedo()
            } else {
                toolbarUndo()
            }
        case 17 where event.modifierFlags.contains(.command):
            commitPin()
        default: break
        }
    }

    fileprivate var currentSelection: CaptureSelection? { selection }
}

// MARK: - Panel / View

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class OverlayView: NSView, NSTextFieldDelegate {
    weak var controller: CaptureOverlayController?
    var screenFrame: ScreenFrame?
    /// 长截浮动结果：无全屏遮罩暗角，仅展示图片。
    var floatingResult = false

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()
    private let selectionBorder = CAShapeLayer()
    private let annotationLayer = CALayer()
    private var tracking: NSTrackingArea?
    private var appliedSelection: CaptureSelection?

    private var textField: NSTextField?
    private var onTextCommit: ((String) -> Void)?
    private var onTextCancel: (() -> Void)?
    private var ocrOverlay: OCRTextOverlayView?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    /// 长截时选区内穿透，滚轮/点击落到下层 App。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if controller?.isScrollCapturing == true,
           let sel = appliedSelection {
            let local = convertFromGlobal(sel.logicalRect)
            if local.contains(point) {
                return nil
            }
        }
        return super.hitTest(point)
    }

    /// 非 key 窗口上的首击也要进 mouseDown；否则首拖只激活遮罩，看起来像拖选无效。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func currentText() -> String { textField?.stringValue ?? "" }

    func installOCR(
        lines: [OCRLine],
        selectionGlobal: CGRect,
        imagePixelSize: CGSize,
        scale: CGFloat
    ) {
        removeOCR()
        let frame = convertFromGlobal(selectionGlobal)
        let overlay = OCRTextOverlayView(frame: frame)
        overlay.apply(lines: lines, imagePixelSize: imagePixelSize, scale: scale)
        addSubview(overlay)
        ocrOverlay = overlay
    }

    func removeOCR() {
        ocrOverlay?.teardown()
        ocrOverlay?.removeFromSuperview()
        ocrOverlay = nil
    }

    @discardableResult
    func copyOCRSelection() -> Bool {
        ocrOverlay?.copySelectionToPasteboard() ?? false
    }

    func selectAllOCR() {
        ocrOverlay?.selectAll()
    }

    /// 供外部把焦点交给 OCR 叠层（⌘A / 双击选词等）。
    var ocrOverlayForFocus: NSView? { ocrOverlay }

    /// 当前编辑文字在选区内的绘制原点（与 CALayer/`makeTextCGImage` 顶对齐一致）。
    func textDrawOriginInSelectionLocal(
        selectionGlobal: CGRect,
        text: String,
        fontSize: CGFloat
    ) -> CGPoint? {
        guard let origin = textDrawOriginInView(text: text, fontSize: fontSize),
              selectionGlobal != .zero
        else { return nil }
        let sel = convertFromGlobal(selectionGlobal)
        return CGPoint(x: origin.x - sel.minX, y: origin.y - sel.minY)
    }

    /// 编辑器可见文字 → 成稿字框左下角（view 坐标）。
    /// 用字形包围盒顶边（非 firstRect 行框）对齐成稿 `draw(in:)` 顶边；Y 向下像素对齐消除上偏。
    private func textDrawOriginInView(text: String, fontSize: CGFloat) -> CGPoint? {
        guard let editor = textField?.currentEditor() as? NSTextView,
              let window,
              let layout = editor.layoutManager,
              let container = editor.textContainer
        else { return nil }
        let length = (text as NSString).length
        guard length > 0 else { return nil }

        let charRange = NSRange(location: 0, length: length)
        let glyphRange = layout.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let inView: CGRect
        if glyphRange.length > 0 {
            var glyphBounds = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            let containerOrigin = editor.textContainerOrigin
            glyphBounds = glyphBounds.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
            inView = convert(editor.convert(glyphBounds, to: nil), from: nil)
        } else {
            let screen = editor.firstRect(forCharacterRange: charRange, actualRange: nil)
            guard screen.height > 0 else { return nil }
            inView = convert(window.convertFromScreen(screen), from: nil)
        }

        let drawSize = AnnotationController.textSize(text: text, fontSize: fontSize)
        let scale = window.backingScaleFactor
        // 顶对齐：origin.y = top - height；floor 避免 CALayer 亚像素上取整造成的微上偏
        let y = floor((inView.maxY - drawSize.height) * scale) / scale
        let x = (inView.minX * scale).rounded() / scale
        return CGPoint(x: x, y: y)
    }

    func beginTextInput(
        selectionLocal: CGPoint,
        selectionGlobal: CGRect,
        fontSize: CGFloat,
        color: NSColor,
        initial: String,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        endTextInput()
        onTextCommit = onCommit
        onTextCancel = onCancel

        let selLocal = convertFromGlobal(selectionGlobal)
        let origin = CGPoint(x: selLocal.minX + selectionLocal.x, y: selLocal.minY + selectionLocal.y)
        let font = AnnotationController.textFont(size: fontSize)
        let height = ceil(font.ascender - font.descender) + 6
        let width = min(360, max(120, bounds.width - origin.x - 8))

        let field = NSTextField(frame: CGRect(x: origin.x, y: origin.y, width: width, height: height))
        field.font = font
        field.textColor = color
        field.stringValue = initial
        field.placeholderString = ""
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        if let cell = field.cell as? NSTextFieldCell {
            cell.drawsBackground = false
            cell.backgroundColor = .clear
        }
        field.delegate = self
        field.target = self
        field.action = #selector(commitTextField)
        // 校准完成前不显示：field editor 挂在 window 上，需一并藏
        field.alphaValue = 0
        addSubview(field)
        textField = field

        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.alphaValue = 0
        }
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field else { return }
            self.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else {
                field.alphaValue = 1
                return
            }
            editor.alphaValue = 0
            let caretIndex = initial.count
            editor.selectedRange = NSRange(location: caretIndex, length: 0)
            // 新输入：点击对齐插入条中心；再编辑：selectionLocal 已是字框左下角
            let anchor: TextAlignAnchor = initial.isEmpty ? .caretCenter : .drawOrigin
            self.alignTextField(field, editor: editor, caretIndex: caretIndex, to: origin, anchor: anchor)
            self.reseatFieldEditor(field, editor: editor, caretIndex: caretIndex, color: color)
            editor.alphaValue = 0
            self.alignTextField(field, editor: editor, caretIndex: caretIndex, to: origin, anchor: anchor)
            self.reseatFieldEditor(field, editor: editor, caretIndex: caretIndex, color: color)
            editor.alphaValue = 1
            field.alphaValue = 1
        }
    }

    private enum TextAlignAnchor {
        case caretCenter // (minX, midY) — 新输入点击
        case drawOrigin  // (minX, minY) — 与成稿字框左下角一致
    }

    /// 将 field editor 指定锚点平移到目标点。
    private func alignTextField(
        _ field: NSTextField,
        editor: NSTextView,
        caretIndex: Int,
        to target: CGPoint,
        anchor: TextAlignAnchor
    ) {
        guard let window else { return }
        let anchorInView: CGPoint
        switch anchor {
        case .caretCenter:
            let caretScreen = editor.firstRect(
                forCharacterRange: NSRange(location: caretIndex, length: 0),
                actualRange: nil
            )
            guard caretScreen.height > 0 else { return }
            let caretWindow = window.convertFromScreen(caretScreen)
            anchorInView = convert(
                CGPoint(x: caretWindow.minX, y: caretWindow.midY),
                from: nil
            )
        case .drawOrigin:
            let fontSize = field.font?.pointSize ?? 18
            guard let origin = textDrawOriginInView(text: field.stringValue, fontSize: fontSize) else { return }
            anchorInView = origin
        }
        let dx = target.x - anchorInView.x
        let dy = target.y - anchorInView.y
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
        field.setFrameOrigin(NSPoint(
            x: field.frame.origin.x + dx,
            y: field.frame.origin.y + dy
        ))
    }

    private func reseatFieldEditor(
        _ field: NSTextField,
        editor: NSTextView,
        caretIndex: Int,
        color: NSColor
    ) {
        field.cell?.select(
            withFrame: field.bounds,
            in: field,
            editor: editor,
            delegate: self,
            start: caretIndex,
            length: 0
        )
        editor.insertionPointColor = color
    }

    func endTextInput() {
        textField?.delegate = nil
        textField?.removeFromSuperview()
        textField = nil
        onTextCommit = nil
        onTextCancel = nil
    }

    @objc private func commitTextField() {
        let text = textField?.stringValue ?? ""
        onTextCommit?(text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextField()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onTextCancel?()
            return true
        }
        return false
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
        dimLayer.frame = bounds
        hoverLayer.frame = bounds
        selectionBorder.frame = bounds
        annotationLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    func installLayers() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor

        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        // 直接用 NSImage 承载 CGImage，不做额外 Y 翻转（翻转会导致整屏颠倒）
        if let cg = screenFrame?.image {
            imageLayer.contents = NSImage(cgImage: cg, size: bounds.size)
        }

        // 仅选区外变暗；选区内完全透明、无蒙版色
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dimLayer.fillRule = .evenOdd
        dimLayer.frame = bounds
        dimLayer.allowsEdgeAntialiasing = false

        // 窗口悬停：仅描边提示可吸附，不加蓝色填充蒙版
        hoverLayer.fillColor = nil
        hoverLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        hoverLayer.lineWidth = 2
        hoverLayer.lineDashPattern = [6, 4]
        hoverLayer.frame = bounds
        hoverLayer.isHidden = true
        hoverLayer.allowsEdgeAntialiasing = false

        selectionBorder.fillColor = nil
        selectionBorder.strokeColor = NSColor.white.cgColor
        selectionBorder.lineWidth = 2
        selectionBorder.frame = bounds
        selectionBorder.allowsEdgeAntialiasing = false
        selectionBorder.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        annotationLayer.frame = bounds
        annotationLayer.masksToBounds = false

        layer?.addSublayer(imageLayer)
        layer?.addSublayer(dimLayer)
        layer?.addSublayer(hoverLayer)
        layer?.addSublayer(selectionBorder)
        layer?.addSublayer(annotationLayer)

        let path = CGMutablePath()
        path.addRect(bounds)
        dimLayer.path = path
    }

    func apply(
        selection: CaptureSelection?,
        hover: WindowHit?,
        shapes: [Shape],
        draft: Shape?,
        locked: Bool,
        scrollCapturing: Bool = false,
        scrollPreview: CGImage? = nil
    ) {
        guard let screenFrame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        imageLayer.mask = nil
        annotationLayer.isHidden = scrollCapturing

        if floatingResult {
            // 完成后的浮动预览：整窗显示结果图
            imageLayer.opacity = 1
            imageLayer.contentsGravity = .resize
            imageLayer.frame = bounds
            imageLayer.contents = NSImage(cgImage: screenFrame.image, size: bounds.size)
            dimLayer.fillColor = NSColor.clear.cgColor
            dimLayer.path = nil
            selectionBorder.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
            selectionBorder.lineWidth = 2
        } else if scrollCapturing {
            // 长截：灰区+选区洞露实况；拼接预览在侧边 ScrollCapturePreview
            imageLayer.opacity = 0
            imageLayer.contents = nil
            imageLayer.frame = bounds
            imageLayer.mask = nil
            dimLayer.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
            selectionBorder.strokeColor = NSColor.systemBlue.cgColor
            selectionBorder.lineWidth = 3
            _ = scrollPreview
        } else {
            // 普通截图：全屏冻结图 + 选区挖空预览
            imageLayer.opacity = 1
            imageLayer.contentsGravity = .resize
            imageLayer.frame = bounds
            imageLayer.contents = NSImage(cgImage: screenFrame.image, size: bounds.size)
            dimLayer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
            selectionBorder.strokeColor = NSColor.white.cgColor
            selectionBorder.lineWidth = 2
        }

        let dimPath = CGMutablePath()
        if !floatingResult {
            dimPath.addRect(bounds)
        }

        appliedSelection = selection
        if let sel = selection, sel.screenID == screenFrame.screenID {
            let local = pixelAlign(convertFromGlobal(sel.logicalRect))
            if !floatingResult {
                dimPath.addRect(local)
            }
            let border = local.insetBy(dx: -1, dy: -1)
            selectionBorder.path = CGPath(rect: border, transform: nil)
            selectionBorder.isHidden = false
            if scrollCapturing {
                annotationLayer.sublayers = nil
            } else {
                renderAnnotations(shapes: shapes, draft: draft, in: local)
            }
        } else {
            selectionBorder.path = nil
            selectionBorder.isHidden = true
            annotationLayer.sublayers = nil
        }

        if !floatingResult {
            dimLayer.path = dimPath
        }

        if let hover, !locked {
            let local = pixelAlign(convertFromGlobal(hover.logicalBounds))
            if bounds.intersects(local) {
                hoverLayer.path = CGPath(rect: local.insetBy(dx: -1, dy: -1), transform: nil)
                hoverLayer.isHidden = false
            } else {
                hoverLayer.isHidden = true
            }
        } else {
            hoverLayer.isHidden = true
        }

        CATransaction.commit()
    }

    /// 对齐到物理像素，消除拖动时边框亚像素抖动。
    private func pixelAlign(_ rect: CGRect) -> CGRect {
        let s = max(window?.backingScaleFactor ?? screenFrame?.scale ?? 2, 1)
        return CGRect(
            x: (rect.minX * s).rounded() / s,
            y: (rect.minY * s).rounded() / s,
            width: max(1 / s, (rect.width * s).rounded() / s),
            height: max(1 / s, (rect.height * s).rounded() / s)
        )
    }

    private func renderAnnotations(shapes: [Shape], draft: Shape?, in selectionLocal: CGRect) {
        annotationLayer.sublayers = nil
        annotationLayer.contents = nil
        annotationLayer.compositingFilter = nil

        let all = shapes + (draft.map { [$0] } ?? [])
        guard !all.isEmpty else {
            annotationLayer.frame = bounds
            return
        }

        let selectionBase = selectionPixelImage()
        let scaleX: CGFloat
        let scaleY: CGFloat
        if let base = selectionBase, let sel = appliedSelection, sel.logicalRect.width > 0, sel.logicalRect.height > 0 {
            scaleX = CGFloat(base.width) / sel.logicalRect.width
            scaleY = CGFloat(base.height) / sel.logicalRect.height
        } else {
            let s = screenFrame?.scale ?? 2
            scaleX = s
            scaleY = s
        }

        // 有橡皮时 CAShapeLayer + destinationOut 不可靠，统一走与导出相同的标注位图。
        let needsBitmap = all.contains { $0.kind == .eraser || $0.kind == .mosaic || $0.kind == .blur }
        if needsBitmap {
            var pixelShapes: [Shape] = []
            let scale = max(scaleX, scaleY)
            for shape in all {
                var s = shape
                s.points = shape.points.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }
                s.lineWidth = shape.lineWidth * scale
                pixelShapes.append(s)
            }
            let pw = max(1, Int(ceil(selectionLocal.width * scaleX)))
            let ph = max(1, Int(ceil(selectionLocal.height * scaleY)))
            if let overlay = AnnotationController.renderAnnotationOverlay(
                shapes: pixelShapes,
                pixelWidth: pw,
                pixelHeight: ph,
                base: selectionBase
            ) {
                annotationLayer.frame = selectionLocal
                annotationLayer.contents = NSImage(cgImage: overlay, size: selectionLocal.size)
                annotationLayer.contentsGravity = .resize
                return
            }
        }

        annotationLayer.frame = bounds
        for shape in all {
            guard let shapeLayer = makeShapeLayer(
                shape,
                origin: selectionLocal.origin,
                selectionBase: selectionBase,
                scaleX: scaleX,
                scaleY: scaleY
            ) else { continue }
            annotationLayer.addSublayer(shapeLayer)
        }
    }

    /// 选区对应截图像素（相对 `ScreenFrame.logicalBounds`，与导出一致）。
    private func selectionPixelImage() -> CGImage? {
        guard let sf = screenFrame, let sel = appliedSelection else { return nil }
        let lw = sf.logicalBounds.width
        let lh = sf.logicalBounds.height
        guard lw > 0, lh > 0 else { return nil }
        let sx = CGFloat(sf.image.width) / lw
        let sy = CGFloat(sf.image.height) / lh
        let originInScreen = CGPoint(
            x: sel.logicalRect.minX - sf.logicalBounds.minX,
            y: sel.logicalRect.minY - sf.logicalBounds.minY
        )
        let pixelRect = CGRect(
            x: originInScreen.x * sx,
            y: originInScreen.y * sy,
            width: sel.logicalRect.width * sx,
            height: sel.logicalRect.height * sy
        )
        return ImageExporter().crop(sf.image, pixelRect: pixelRect)
    }

    private func makeShapeLayer(
        _ shape: Shape,
        origin: CGPoint,
        selectionBase: CGImage?,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CALayer? {
        let pts = shape.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
        guard let first = pts.first else { return nil }
        let color = shape.nsColor.cgColor
        let layer = CAShapeLayer()
        layer.strokeColor = color
        layer.fillColor = nil
        layer.lineWidth = shape.lineWidth
        layer.lineJoin = .round
        layer.lineCap = .round

        switch shape.kind {
        case .rect:
            guard let last = pts.last else { return nil }
            let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                           width: abs(last.x - first.x), height: abs(last.y - first.y))
            layer.path = CGPath(rect: r, transform: nil)
        case .ellipse:
            guard let last = pts.last else { return nil }
            let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                           width: abs(last.x - first.x), height: abs(last.y - first.y))
            layer.path = CGPath(ellipseIn: r, transform: nil)
        case .line, .arrow, .freehand, .marker:
            let path = CGMutablePath()
            path.move(to: first)
            for p in pts.dropFirst() { path.addLine(to: p) }
            if shape.kind == .arrow, let last = pts.last {
                let angle = atan2(last.y - first.y, last.x - first.x)
                let len: CGFloat = 12
                path.move(to: last)
                path.addLine(to: CGPoint(x: last.x + cos(angle + .pi * 0.8) * len, y: last.y + sin(angle + .pi * 0.8) * len))
                path.move(to: last)
                path.addLine(to: CGPoint(x: last.x + cos(angle - .pi * 0.8) * len, y: last.y + sin(angle - .pi * 0.8) * len))
            }
            layer.path = path
        case .eraser:
            // 预览走位图路径；此处不应到达
            return nil
        case .highlight:
            guard let last = pts.last else { return nil }
            let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                           width: abs(last.x - first.x), height: abs(last.y - first.y))
            layer.path = CGPath(rect: r, transform: nil)
            layer.fillColor = shape.nsColor.withAlphaComponent(0.35).cgColor
            layer.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
        case .mosaic, .blur:
            guard let last = pts.last else { return nil }
            let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                           width: abs(last.x - first.x), height: abs(last.y - first.y))
            if let patchLayer = makeFilterPreviewLayer(
                kind: shape.kind,
                viewRect: r,
                selectionOrigin: origin,
                selectionBase: selectionBase,
                scaleX: scaleX,
                scaleY: scaleY
            ) {
                return patchLayer
            }
            // 滤镜失败时也给可见反馈，避免「完全没效果」
            layer.path = CGPath(rect: r, transform: nil)
            layer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
            layer.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
            layer.lineWidth = 1
        case .text:
            let text = shape.text ?? ""
            guard !text.isEmpty else { return nil }
            let fontSize = max(12, shape.lineWidth)
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            guard let cg = AnnotationController.makeTextCGImage(
                text: text,
                color: shape.nsColor,
                fontSize: fontSize,
                scale: scale
            ) else { return nil }
            let size = AnnotationController.textSize(text: text, fontSize: fontSize)
            let textLayer = CALayer()
            textLayer.contents = cg
            textLayer.contentsGravity = .resize
            textLayer.contentsScale = scale
            textLayer.frame = CGRect(origin: first, size: size)
            return textLayer
        case .number:
            return nil
        }
        return layer
    }

    /// 马赛克 / 模糊实时预览（与 `exportFlattened` 同一滤镜路径）。REQ: E-008
    private func makeFilterPreviewLayer(
        kind: ShapeKind,
        viewRect: CGRect,
        selectionOrigin: CGPoint,
        selectionBase: CGImage?,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CALayer? {
        guard let selectionBase, viewRect.width >= 2, viewRect.height >= 2 else { return nil }
        let local = viewRect.offsetBy(dx: -selectionOrigin.x, dy: -selectionOrigin.y)
        // 形状点相对 sel.logicalRect；selectionOrigin 可能经 pixelAlign 微调，用 appliedSelection 原点更稳
        let logicalLocal: CGRect
        if let sel = appliedSelection {
            let viewSel = convertFromGlobal(sel.logicalRect)
            logicalLocal = viewRect.offsetBy(dx: -viewSel.minX, dy: -viewSel.minY)
        } else {
            logicalLocal = local
        }
        let pixelRect = CGRect(
            x: logicalLocal.minX * scaleX,
            y: logicalLocal.minY * scaleY,
            width: logicalLocal.width * scaleX,
            height: logicalLocal.height * scaleY
        )
        let block = max(8, Int((8 * max(scaleX, scaleY)).rounded()))
        guard let patch = AnnotationController.filteredPatch(
            kind: kind,
            rectInBottomLeftPixels: pixelRect,
            base: selectionBase,
            mosaicBlock: CGFloat(block)
        ) else { return nil }

        let content = CALayer()
        content.frame = viewRect
        content.contents = patch
        content.contentsGravity = .resize
        content.contentsScale = 1
        content.minificationFilter = .nearest
        content.magnificationFilter = .nearest
        return content
    }

    private func convertFromGlobal(_ rect: CGRect) -> CGRect {
        guard let window else { return .zero }
        let frame = window.frame
        return CGRect(
            x: rect.minX - frame.minX,
            y: rect.minY - frame.minY,
            width: rect.width,
            height: rect.height
        )
    }

    private func global(from local: NSPoint) -> CGPoint {
        guard let window else { return local }
        let f = window.frame
        return CGPoint(x: local.x + f.minX, y: local.y + f.minY)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        makeFirstResponderUnlessEditing()
        let p = global(from: convert(event.locationInWindow, from: nil))
        if event.clickCount >= 2 {
            controller?.mouseDoubleClick(at: p)
        } else {
            controller?.mouseDown(at: p)
        }
    }

    private func makeFirstResponderUnlessEditing() {
        guard textField == nil, ocrOverlay == nil else { return }
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.mouseDragged(at: global(from: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        controller?.mouseUp(at: global(from: convert(event.locationInWindow, from: nil)))
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.mouseMoved(at: global(from: convert(event.locationInWindow, from: nil)))
    }

    override func cursorUpdate(with event: NSEvent) {
        controller?.updateCursor(at: global(from: convert(event.locationInWindow, from: nil)))
    }

    override func resetCursorRects() {
        // 交给 mouseMoved / cursorUpdate 动态设置
    }

    override func keyDown(with event: NSEvent) {
        // 文字输入 / OCR 选区：快捷键由 monitor 或显式 copy 处理
        if textField != nil { return }
        if ocrOverlay != nil { return }
        controller?.keyDown(event)
    }
}


/// 条码 / 二维码结果条：展示内容，一键复制或打开链接。
@MainActor
final class OCRCodeResultBar: NSPanel {
    private let payload: String
    private let onDismiss: () -> Void

    init(payload: String, under selection: CGRect, onDismiss: @escaping () -> Void) {
        self.payload = payload
        self.onDismiss = onDismiss
        let width: CGFloat = 420
        let height: CGFloat = 44
        var x = selection.midX - width / 2
        var y = selection.minY - height - 12
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection) })
            ?? NSScreen.main {
            x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - width - 8)
            if y < screen.frame.minY + 8 {
                y = min(selection.maxY + 12, screen.frame.maxY - height - 8)
            }
        }
        super.init(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let chrome = NSVisualEffectView(frame: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
        chrome.material = .popover
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 10
        chrome.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: payload)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = payload
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let copyBtn = NSButton(title: "复制", target: self, action: #selector(copyPayload))
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .small

        let openBtn = NSButton(title: "打开", target: self, action: #selector(openPayload))
        openBtn.bezelStyle = .rounded
        openBtn.controlSize = .small
        openBtn.isHidden = !Self.canOpen(payload)

        let stack = NSStackView(views: [label, copyBtn, openBtn])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            stack.topAnchor.constraint(equalTo: chrome.topAnchor),
            stack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
            copyBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            openBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        contentView = chrome
    }

    func present() {
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyPayload() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload, forType: .string)
        onDismiss()
    }

    @objc private func openPayload() {
        let raw = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if let u = URL(string: raw), u.scheme != nil {
            url = u
        } else if looksLikeURL(raw) {
            url = URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)")
        } else {
            url = nil
        }
        if let url {
            NSWorkspace.shared.open(url)
        }
        onDismiss()
    }

    private static func canOpen(_ s: String) -> Bool {
        let raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
            return true
        }
        if let u = URL(string: raw), let scheme = u.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return true
        }
        return raw.contains(".") && !raw.contains(" ") && raw.count >= 4
    }

    private func looksLikeURL(_ s: String) -> Bool { Self.canOpen(s) }

    override var canBecomeKey: Bool { true }
}

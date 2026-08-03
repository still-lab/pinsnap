import AppKit
import CoreGraphics
import Foundation
import QuartzCore

public enum CaptureOverlayOutcome: Sendable {
    case cancelled
    case copied(CGImage)
    case saved(CGImage)
    case pinned(CGImage, frame: CGRect)
}

/// 截图遮罩：图层化渲染 + 选区固定后标注工具条。
/// REQ: C-01, C-02, C-06 / UI_SPEC §3
@MainActor
public final class CaptureOverlayController: NSObject, CaptureToolbarDelegate {
    public var onFinish: ((CaptureOverlayOutcome) -> Void)?
    public var onNeedUpgrade: (() -> Void)?
    public var annotationEnabled = true
    public var autoCopyOnSelect = false

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
    private var activeTool: CaptureAnnotateTool?
    private var shapeStyle: CaptureShapeStyle = .rect
    private var arrowStyle: CaptureArrowStyle = .arrow
    private var mosaicStyle: CaptureMosaicStyle = .mosaic
    private var draftShape: Shape?
    private var annotateStart: CGPoint?
    private var moveGrabStart: CGPoint?
    private var moveOriginRect: CGRect?

    private var lastHoverSample = Date.distantPast
    private let hoverInterval: TimeInterval = 1.0 / 30.0
    private var keyMonitor: Any?
    private var rightClickMonitor: Any?
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

    public func present(frames: [ScreenFrame]) {
        dismiss()
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
        panels.first?.makeKeyAndOrderFront(nil)
        panels.first.flatMap { ($0.contentView as? OverlayView) }?.window?.makeFirstResponder(panels.first?.contentView)
        installEscapeHatches()
        syncLayers()
    }

    public func dismiss() {
        exitOCRMode()
        closeTextEditor(commit: false)
        removeEscapeHatches()
        toolbar?.orderOut(nil)
        toolbar = nil
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
        draftShape = nil
        annotateStart = nil
        moveGrabStart = nil
        moveOriginRect = nil
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
            switch event.keyCode {
            case 36, 76:
                self.commitCopy()
                return nil
            case 8 where cmd:
                self.commitCopy()
                return nil
            case 1 where cmd:
                self.commitSave()
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
    }

    private func handleEscape() {
        if isEditingText {
            closeTextEditor(commit: false)
            return
        }
        if isOCRSelecting {
            exitOCRMode()
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
        if isOCRSelecting { return }
        if isEditingText {
            // 点在输入框外：提交当前文字
            finishTextInput(textHostView?.currentText() ?? "")
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
        if isOCRSelecting { return }
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
        if isOCRSelecting { return }
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
        guard !selectionLocked, drag.dragStart == nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHoverSample) >= hoverInterval else { return }
        lastHoverSample = now
        let hit = windows.hit(at: global)
        if hit?.windowID != hoverWindow?.windowID || hit?.logicalBounds != hoverWindow?.logicalBounds {
            hoverWindow = hit
            syncLayers()
        }
    }

    fileprivate func updateCursor(at global: CGPoint) {
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
        guard selectionLocked, activeTool == .text, let sel = selection, sel.logicalRect.contains(global) else {
            NSCursor.arrow.set()
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
        selectionLocked = true
        showToolbar()
        syncLayers()
    }

    // MARK: - Annotate

    private func handleAnnotateMouseDown(at global: CGPoint) {
        guard let sel = selection, sel.logicalRect.contains(global) else {
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
            syncLayers()
            return
        }
        // 未选标注工具时：拖动移动选区
        if activeTool == nil {
            moveGrabStart = global
            moveOriginRect = sel.logicalRect
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
        draftShape = Shape(kind: kind, lineWidth: activeTool == .pen ? 3 : 2, points: [local])
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
                repositionToolbar()
                syncLayers()
            }
            return
        }
        guard var draft = draftShape, let start = annotateStart, activeTool != nil else { return }
        let local = toSelectionLocal(global)
        if draft.kind == .freehand {
            draft.points.append(local)
        } else {
            draft.points = [start, local]
        }
        draftShape = draft
        syncLayers()
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
            return
        }
        guard var draft = draftShape else {
            annotateStart = nil
            return
        }
        let local = toSelectionLocal(global)
        if draft.kind == .freehand {
            draft.points.append(local)
        } else if let start = annotateStart {
            draft.points = [start, local]
        }
        if draft.kind != .freehand {
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
                hover: selectionLocked ? nil : hoverWindow,
                shapes: annotations.document.shapes.filter { $0.id != hideID },
                draft: draftShape,
                locked: selectionLocked
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
        case .pen: return .freehand
        case .mosaic:
            return mosaicStyle == .blur ? .blur : .mosaic
        case .text: return .text
        case .none: return nil
        }
    }

    func toolbarSelectTool(_ tool: CaptureAnnotateTool?) {
        exitOCRMode()
        closeTextEditor(commit: false)
        activeTool = tool
        if let sel = selection {
            updateCursor(at: CGPoint(x: sel.logicalRect.midX, y: sel.logicalRect.midY))
        } else {
            NSCursor.arrow.set()
        }
    }

    func toolbarSelectShapeStyle(_ style: CaptureShapeStyle) {
        shapeStyle = style
        activeTool = .shape
    }

    func toolbarSelectArrowStyle(_ style: CaptureArrowStyle) {
        arrowStyle = style
        activeTool = .arrow
    }

    func toolbarSelectMosaicStyle(_ style: CaptureMosaicStyle) {
        mosaicStyle = style
        activeTool = .mosaic
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
    func toolbarClose() { cancel() }

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
        dismiss()
        onFinish?(.cancelled)
    }

    fileprivate func commitCopy() {
        guard let image = exportImage() else { return }
        try? exporter.copyToClipboard(image)
        dismiss()
        onFinish?(.copied(image))
    }

    fileprivate func commitSave() {
        guard let image = exportImage() else {
            PinSnapLog.app.error("save: exportImage returned nil")
            return
        }

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
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = FilenameTemplate.default.render(width: image.width, height: image.height) + ".png"
        panel.level = .modalPanel

        let result = panel.runModal()

        if previousPolicy != .regular {
            NSApp.setActivationPolicy(previousPolicy)
        }

        guard result == .OK, let url = panel.url else {
            // 取消：恢复遮罩与工具条
            for p in overlayPanels { p.orderFrontRegardless() }
            if selectionLocked {
                showToolbar()
            }
            return
        }

        do {
            try exporter.save(image, to: url, format: .png)
            dismiss()
            onFinish?(.saved(image))
        } catch {
            PinSnapLog.app.error("save failed: \(error.localizedDescription)")
            for p in overlayPanels { p.orderFrontRegardless() }
            if selectionLocked {
                showToolbar()
            }
        }
    }

    fileprivate func commitPin() {
        guard let image = exportImage(), let selection else { return }
        let frame = selection.logicalRect
        dismiss()
        onFinish?(.pinned(image, frame: frame))
    }

    private func exportImage() -> CGImage? {
        guard let selection,
              let frame = frames.first(where: { $0.screenID == selection.screenID }),
              let base = exporter.crop(frame: frame, selection: selection, geometry: geometry)
        else { return nil }
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
        guard selection != nil else { return }
        if toolbar == nil {
            let bar = CaptureToolbar()
            bar.actionHandler = self
            toolbar = bar
        }
        guard let toolbar else { return }
        toolbar.setShapeStyle(shapeStyle)
        toolbar.setArrowStyle(arrowStyle)
        toolbar.setMosaicStyle(mosaicStyle)
        toolbar.setSelectedTool(activeTool)
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
                hover: selectionLocked ? nil : hoverWindow,
                shapes: annotations.document.shapes,
                draft: draftShape,
                locked: selectionLocked
            )
        }
    }

    fileprivate func keyDown(_ event: NSEvent) {
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
        case 1 where event.modifierFlags.contains(.command): commitSave()
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
        locked: Bool
    ) {
        guard let screenFrame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let dimPath = CGMutablePath()
        dimPath.addRect(bounds)

        appliedSelection = selection
        if let sel = selection, sel.screenID == screenFrame.screenID {
            let local = pixelAlign(convertFromGlobal(sel.logicalRect))
            dimPath.addRect(local)
            // 描边画在选区外侧（线宽一半），避免与挖空边抢同一像素导致闪动
            let border = local.insetBy(dx: -1, dy: -1)
            selectionBorder.path = CGPath(rect: border, transform: nil)
            selectionBorder.isHidden = false
            renderAnnotations(shapes: shapes, draft: draft, in: local)
        } else {
            selectionBorder.path = nil
            selectionBorder.isHidden = true
            annotationLayer.sublayers = nil
        }

        dimLayer.path = dimPath

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
        let all = shapes + (draft.map { [$0] } ?? [])
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
        case .line, .arrow, .freehand:
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
        let p = global(from: convert(event.locationInWindow, from: nil))
        if event.clickCount >= 2 {
            controller?.mouseDoubleClick(at: p)
        } else {
            controller?.mouseDown(at: p)
        }
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


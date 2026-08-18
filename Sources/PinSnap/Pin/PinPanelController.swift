import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
public final class PinPanelController: NSObject, NSWindowDelegate, PinAnnotateToolbarDelegate {
    private let item: PinItem
    private let imageURL: URL
    private weak var store: PinStore?
    private var panel: NSPanel!
    private var imageView: PinContentView!
    private var annotationView: PinAnnotateCanvas?
    private var annotateToolbar: PinAnnotateToolbar?
    private var annotations = AnnotationController()
    private var baseCGImage: CGImage?
    private var isAnnotating = false
    private var currentScale: CGFloat
    private var currentAlpha: CGFloat
    /// 创建时逻辑尺寸（scale=1），滚轮/捏合相对此基准。
    private let baseSize: NSSize

    private var activeTool: CaptureAnnotateTool?
    private var shapeStyle: CaptureShapeStyle = .rect
    private var arrowStyle: CaptureArrowStyle = .arrow
    private var mosaicStyle: CaptureMosaicStyle = .mosaic
    private var penStyle: CapturePenStyle = .pen
    private var strokeHue: CGFloat = StrokeColorStrip.defaultHue

    init(item: PinItem, imageURL: URL, store: PinStore) {
        self.item = item
        self.imageURL = imageURL
        self.store = store
        self.currentScale = max(0.2, item.scale)
        self.currentAlpha = item.alpha
        let s = max(0.2, item.scale)
        self.baseSize = NSSize(
            width: item.frame.width / s,
            height: item.frame.height / s
        )
        super.init()

        let panel = NSPanel(
            contentRect: item.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let imageView = PinContentView(frame: NSRect(origin: .zero, size: item.frame.size))
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = NSImage(contentsOf: imageURL)
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        imageView.onDoubleClick = { [weak self] in
            self?.copyAndDestroy()
        }
        imageView.onScroll = { [weak self] event in
            self?.handleScroll(event)
        }
        panel.contentView = imageView
        panel.alphaValue = item.alpha
        panel.ignoresMouseEvents = item.ignoresMouse

        self.panel = panel
        self.imageView = imageView
        if let img = imageView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            baseCGImage = img
        }

        let mag = NSMagnificationGestureRecognizer(target: self, action: #selector(onMagnify(_:)))
        imageView.addGestureRecognizer(mag)

        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "标注", action: #selector(beginAnnotate), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "复制", action: #selector(copyImage), keyEquivalent: "")
        menu.addItem(withTitle: "保存…", action: #selector(saveImage), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let opacity = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for (title, value) in [("100%", 1.0), ("75%", 0.75), ("50%", 0.5), ("25%", 0.25)] as [(String, CGFloat)] {
            let item = NSMenuItem(title: title, action: #selector(setOpacityFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            opacityMenu.addItem(item)
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "关闭", action: #selector(closePin), keyEquivalent: "")
        menu.addItem(withTitle: "销毁", action: #selector(destroyPin), keyEquivalent: "")
        for menuItem in menu.items where menuItem.submenu == nil { menuItem.target = self }
        imageView.menu = isAnnotating ? nil : menu
    }

    func show() {
        panel.setFrame(item.frame, display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        endAnnotate(commit: false)
        panel.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    func setClickThrough(_ enabled: Bool) {
        panel.ignoresMouseEvents = enabled
    }

    func applyAlpha(_ alpha: CGFloat) {
        currentAlpha = alpha
        panel.alphaValue = alpha
    }

    @objc private func beginAnnotate() {
        guard !isAnnotating else { return }
        if baseCGImage == nil {
            baseCGImage = imageView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard baseCGImage != nil else { return }

        isAnnotating = true
        annotations.reset()
        panel.isMovableByWindowBackground = false
        imageView.allowsWindowMoving = false
        rebuildMenu()

        let canvas = PinAnnotateCanvas(frame: imageView.bounds)
        canvas.autoresizingMask = [.width, .height]
        canvas.delegate = self
        canvas.strokeColor = StrokeColorStrip.color(hue: strokeHue)
        imageView.addSubview(canvas)
        annotationView = canvas

        let bar = PinAnnotateToolbar()
        bar.actionHandler = self
        bar.setStrokeHue(strokeHue)
        bar.place(under: panel.frame)
        annotateToolbar = bar

        refreshAnnotationPreview()
    }

    private func endAnnotate(commit: Bool) {
        guard isAnnotating else { return }
        if commit {
            commitAnnotations()
        }
        annotationView?.removeFromSuperview()
        annotationView = nil
        annotateToolbar?.orderOut(nil)
        annotateToolbar = nil
        annotations.reset()
        isAnnotating = false
        activeTool = nil
        panel.isMovableByWindowBackground = true
        imageView.allowsWindowMoving = true
        rebuildMenu()
    }

    private func commitAnnotations() {
        guard let base = baseCGImage else { return }
        let bounds = imageView.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let sx = CGFloat(base.width) / bounds.width
        let sy = CGFloat(base.height) / bounds.height
        var pixelShapes: [Shape] = []
        for shape in annotations.document.shapes {
            var s = shape
            s.points = shape.points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            s.lineWidth = shape.lineWidth * max(sx, sy)
            pixelShapes.append(s)
        }
        let ctrl = AnnotationController()
        for s in pixelShapes { ctrl.add(s) }
        guard let flat = ctrl.exportFlattened(base: base) else { return }
        do {
            try ImageExporter().save(flat, to: imageURL, format: .png)
            baseCGImage = flat
            imageView.image = NSImage(cgImage: flat, size: imageView.bounds.size)
        } catch {
            PinSnapLog.pin.error("pin annotate save: \(error.localizedDescription)")
        }
    }

    private func refreshAnnotationPreview() {
        guard let canvas = annotationView, let base = baseCGImage else { return }
        let bounds = imageView.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let sx = CGFloat(base.width) / bounds.width
        let sy = CGFloat(base.height) / bounds.height
        var pixelShapes: [Shape] = []
        for shape in annotations.document.shapes + (canvas.draft.map { [$0] } ?? []) {
            var s = shape
            s.points = shape.points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            s.lineWidth = shape.lineWidth * max(sx, sy)
            pixelShapes.append(s)
        }
        let pw = base.width
        let ph = base.height
        if let overlay = AnnotationController.renderAnnotationOverlay(
            shapes: pixelShapes,
            pixelWidth: pw,
            pixelHeight: ph,
            base: base
        ) {
            canvas.previewImage = NSImage(cgImage: overlay, size: bounds.size)
        } else {
            canvas.previewImage = nil
        }
        canvas.needsDisplay = true
    }

    private func currentShapeKind() -> ShapeKind? {
        switch activeTool {
        case .shape: return shapeStyle == .ellipse ? .ellipse : .rect
        case .arrow: return arrowStyle == .line ? .line : .arrow
        case .pen:
            switch penStyle {
            case .pen: return .freehand
            case .marker: return .marker
            case .eraser: return .eraser
            }
        case .mosaic: return mosaicStyle == .blur ? .blur : .mosaic
        case .text: return .text
        case .none: return nil
        }
    }

    // MARK: - PinAnnotateToolbarDelegate

    func pinToolbarSelectTool(_ tool: CaptureAnnotateTool?) {
        activeTool = tool
        annotationView?.activeKind = currentShapeKind()
    }

    func pinToolbarSelectShapeStyle(_ style: CaptureShapeStyle) {
        shapeStyle = style
        activeTool = .shape
        annotationView?.activeKind = currentShapeKind()
    }

    func pinToolbarSelectArrowStyle(_ style: CaptureArrowStyle) {
        arrowStyle = style
        activeTool = .arrow
        annotationView?.activeKind = currentShapeKind()
    }

    func pinToolbarSelectMosaicStyle(_ style: CaptureMosaicStyle) {
        mosaicStyle = style
        activeTool = .mosaic
        annotationView?.activeKind = currentShapeKind()
    }

    func pinToolbarSelectPenStyle(_ style: CapturePenStyle) {
        penStyle = style
        activeTool = .pen
        annotationView?.activeKind = currentShapeKind()
    }

    func pinToolbarSelectStrokeHue(_ hue: CGFloat) {
        strokeHue = StrokeColorStrip.clamp(hue)
        annotationView?.strokeColor = StrokeColorStrip.color(hue: strokeHue)
    }

    func pinToolbarUndo() {
        annotations.undo()
        refreshAnnotationPreview()
    }

    func pinToolbarRedo() {
        annotations.redo()
        refreshAnnotationPreview()
    }

    func pinToolbarDone() {
        endAnnotate(commit: true)
    }

    func pinToolbarCancel() {
        endAnnotate(commit: false)
    }

    @objc private func onMagnify(_ g: NSMagnificationGestureRecognizer) {
        guard !isAnnotating else { return }
        applyScale(currentScale * (1 + g.magnification), anchorInWindow: nil)
        g.magnification = 0
    }

    /// 滚轮缩放；空格+滚轮调透明度。
    private func handleScroll(_ event: NSEvent) {
        guard !isAnnotating else { return }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }

        if Self.isSpaceKeyDown() {
            let next = min(1, max(0.15, currentAlpha + CGFloat(delta) * 0.008))
            currentAlpha = next
            panel.alphaValue = next
            store?.updateAlpha(id: item.id, alpha: next)
            return
        }

        let factor: CGFloat = delta > 0 ? 1.06 : (1 / 1.06)
        let mouseInWindow = panel.mouseLocationOutsideOfEventStream
        applyScale(currentScale * factor, anchorInWindow: mouseInWindow)
    }

    private static func isSpaceKeyDown() -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: 0x31)
    }

    private func applyScale(_ raw: CGFloat, anchorInWindow: CGPoint?) {
        let next = min(4, max(0.2, raw))
        guard abs(next - currentScale) > 0.0001 else { return }

        var f = panel.frame
        let newSize = NSSize(width: baseSize.width * next, height: baseSize.height * next)

        if let anchor = anchorInWindow, f.width > 1, f.height > 1 {
            let ax = anchor.x / f.width
            let ay = anchor.y / f.height
            let globalAnchor = CGPoint(x: f.origin.x + anchor.x, y: f.origin.y + anchor.y)
            f.size = newSize
            f.origin = CGPoint(
                x: globalAnchor.x - newSize.width * ax,
                y: globalAnchor.y - newSize.height * ay
            )
        } else {
            let center = CGPoint(x: f.midX, y: f.midY)
            f.size = newSize
            f.origin = CGPoint(x: center.x - newSize.width / 2, y: center.y - newSize.height / 2)
        }

        currentScale = next
        panel.setFrame(f, display: true)
        imageView.frame = NSRect(origin: .zero, size: newSize)
        store?.updateScale(id: item.id, scale: next, frame: f)
        if isAnnotating {
            annotateToolbar?.place(under: panel.frame)
            refreshAnnotationPreview()
        }
    }

    private func copyAndDestroy() {
        guard !isAnnotating else { return }
        if let img = imageView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            try? ImageExporter().copyToClipboard(img)
        }
        try? store?.destroy(id: item.id)
        Toast.shared.show("已复制")
    }

    @objc private func copyImage() {
        if let img = imageView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            try? ImageExporter().copyToClipboard(img)
        }
    }

    @objc private func saveImage() {
        guard let img = imageView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let format = SavePreferences.saveFormat
        let p = NSSavePanel()
        p.allowedContentTypes = [SavePreferences.contentType(for: format)]
        p.canCreateDirectories = true
        p.isExtensionHidden = false
        p.nameFieldStringValue = SavePreferences.suggestedFileName(
            width: img.width,
            height: img.height,
            format: format
        )
        if let dir = SavePreferences.resolveDirectory(.defaultSave) {
            p.directoryURL = dir
        }
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            if let dir = SavePreferences.resolveDirectory(.defaultSave),
               url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
                try SavePreferences.withSecurityScopedAccess(to: dir) {
                    try ImageExporter().save(img, to: url, format: format)
                }
            } else {
                try ImageExporter().save(img, to: url, format: format)
            }
        } catch {
            PinSnapLog.pin.error("pin save: \(error.localizedDescription)")
        }
    }

    @objc private func setOpacityFromMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        currentAlpha = value
        panel.alphaValue = value
        store?.updateAlpha(id: item.id, alpha: value)
    }

    @objc private func closePin() {
        endAnnotate(commit: false)
        try? store?.close(id: item.id)
    }

    @objc private func destroyPin() {
        endAnnotate(commit: false)
        try? store?.destroy(id: item.id)
    }

    public func windowWillClose(_ notification: Notification) {
        endAnnotate(commit: false)
        store?.panelDidClose(id: item.id)
    }

    public func windowDidMove(_ notification: Notification) {
        store?.updateFrame(id: item.id, frame: panel.frame)
        if isAnnotating {
            annotateToolbar?.place(under: panel.frame)
        }
    }
}

// MARK: - Canvas delegate

extension PinPanelController: PinAnnotateCanvasDelegate {
    fileprivate func canvasDidUpdateDraft(_ draft: Shape?) {
        annotationView?.draft = draft
        refreshAnnotationPreview()
    }

    fileprivate func canvasDidCommit(_ shape: Shape) {
        annotations.add(shape)
        annotationView?.draft = nil
        refreshAnnotationPreview()
    }

    fileprivate func canvasRequestText(at local: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "文字"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        annotations.add(Shape(
            kind: .text,
            lineWidth: 16,
            points: [local],
            text: text,
            color: annotationView?.strokeColor ?? StrokeColorStrip.color(hue: strokeHue)
        ))
        refreshAnnotationPreview()
    }

    fileprivate func canvasDidPressEscape() {
        pinToolbarCancel()
    }
}

/// 贴图上的标注画布（视图坐标，原点左下）。
@MainActor
private final class PinAnnotateCanvas: NSView {
    weak var delegate: PinAnnotateCanvasDelegate?
    var activeKind: ShapeKind?
    var draft: Shape?
    var previewImage: NSImage?
    var strokeColor: NSColor = StrokeColorStrip.color(hue: StrokeColorStrip.defaultHue)

    private var dragStart: CGPoint?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        previewImage?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let kind = activeKind else { return }
        if kind == .text {
            delegate?.canvasRequestText(at: local)
            return
        }
        dragStart = local
        draft = makeDraft(kind: kind, at: local)
        delegate?.canvasDidUpdateDraft(draft)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var draft, let start = dragStart, let kind = activeKind, kind != .text else { return }
        let local = convert(event.locationInWindow, from: nil)
        if isStroke(kind) {
            draft.points.append(local)
        } else {
            draft.points = [start, local]
        }
        self.draft = draft
        delegate?.canvasDidUpdateDraft(draft)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            draft = nil
        }
        guard var draft, let kind = activeKind, kind != .text else { return }
        let local = convert(event.locationInWindow, from: nil)
        if isStroke(kind) {
            draft.points.append(local)
        } else if let start = dragStart {
            draft.points = [start, local]
            let dx = abs(start.x - local.x)
            let dy = abs(start.y - local.y)
            if dx < 2, dy < 2 { return }
        }
        delegate?.canvasDidCommit(draft)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            delegate?.canvasDidPressEscape()
            return
        }
        super.keyDown(with: event)
    }

    private func isStroke(_ kind: ShapeKind) -> Bool {
        kind == .freehand || kind == .marker || kind == .eraser
    }

    private func makeDraft(kind: ShapeKind, at local: CGPoint) -> Shape {
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
            return Shape(kind: .freehand, lineWidth: 3, points: [local], color: strokeColor)
        default:
            return Shape(kind: kind, lineWidth: 2, points: [local], color: strokeColor)
        }
    }
}

@MainActor
private protocol PinAnnotateCanvasDelegate: AnyObject {
    func canvasDidUpdateDraft(_ draft: Shape?)
    func canvasDidCommit(_ shape: Shape)
    func canvasRequestText(at local: CGPoint)
    func canvasDidPressEscape()
}

/// 可拖动；双击复制并销毁；滚轮缩放 / 空格+滚轮透明度。
private final class PinContentView: NSImageView {
    var onDoubleClick: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var allowsWindowMoving = true

    override var mouseDownCanMoveWindow: Bool { allowsWindowMoving }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}

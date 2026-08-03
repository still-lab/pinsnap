import AppKit
import CoreGraphics
import Foundation

public enum CaptureOverlayOutcome: Sendable {
    case cancelled
    case copied(CGImage)
    case saved(CGImage)
    case pinned(CGImage)
}

/// 截图遮罩：暗色 + 选区 + 窗口吸附 + 复制/保存/贴图。
/// REQ: C-01, C-02, C-06
@MainActor
public final class CaptureOverlayController: NSObject {
    public var onFinish: ((CaptureOverlayOutcome) -> Void)?
    public var annotationEnabled = true

    private var panels: [OverlayPanel] = []
    private var frames: [ScreenFrame] = []
    private let geometry = ScreenGeometry()
    private let windows = WindowTracker()
    private let exporter = ImageExporter()
    private var selection: CaptureSelection?
    private var dragStart: CGPoint?
    private var hoverWindow: WindowHit?
    private weak var toolbar: CaptureToolbar?

    public override init() {
        super.init()
    }

    public func present(frames: [ScreenFrame]) {
        dismiss()
        self.frames = frames
        for frame in frames {
            let panel = OverlayPanel(
                contentRect: frame.logicalBounds,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = NSColor.clear
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            let view = OverlayView(frame: NSRect(origin: .zero, size: frame.logicalBounds.size))
            view.screenFrame = frame
            view.controller = self
            panel.contentView = view
            panel.setFrame(frame.logicalBounds, display: true)
            panel.makeKeyAndOrderFront(nil as Any?)
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    public func dismiss() {
        toolbar?.close()
        toolbar = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        selection = nil
        dragStart = nil
    }

    fileprivate func mouseDown(at global: CGPoint) {
        dragStart = global
        hoverWindow = nil
        if let hit = windows.hit(at: global) {
            selection = geometry.clampToSingleScreen(hit.logicalBounds)
            refreshViews()
            showToolbar()
            return
        }
        selection = nil
        refreshViews()
    }

    fileprivate func mouseDragged(at global: CGPoint) {
        guard let start = dragStart else { return }
        let rect = CGRect(
            x: min(start.x, global.x),
            y: min(start.y, global.y),
            width: abs(start.x - global.x),
            height: abs(start.y - global.y)
        )
        selection = geometry.clampToSingleScreen(rect)
        refreshViews()
    }

    fileprivate func mouseUp(at global: CGPoint) {
        mouseDragged(at: global)
        if selection != nil { showToolbar() }
        dragStart = nil
    }

    fileprivate func mouseMoved(at global: CGPoint) {
        guard dragStart == nil else { return }
        hoverWindow = windows.hit(at: global)
        refreshViews()
    }

    fileprivate func cancel() {
        dismiss()
        onFinish?(.cancelled)
    }

    fileprivate func commitCopy() {
        guard let image = croppedImage() else { return }
        try? exporter.copyToClipboard(image)
        dismiss()
        onFinish?(.copied(image))
    }

    fileprivate func commitSave() {
        guard let image = croppedImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = FilenameTemplate.default.render(width: image.width, height: image.height) + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? exporter.save(image, to: url, format: .png)
        dismiss()
        onFinish?(.saved(image))
    }

    fileprivate func commitPin() {
        guard let image = croppedImage() else { return }
        dismiss()
        onFinish?(.pinned(image))
    }

    private func croppedImage() -> CGImage? {
        guard let selection,
              let frame = frames.first(where: { $0.screenID == selection.screenID })
        else { return nil }
        return exporter.crop(frame: frame, selection: selection, geometry: geometry)
    }

    private func refreshViews() {
        for panel in panels {
            (panel.contentView as? OverlayView)?.needsDisplay = true
        }
    }

    private func showToolbar() {
        guard let selection else { return }
        toolbar?.close()
        let bar = CaptureToolbar(controller: self)
        let x = selection.logicalRect.midX - 140
        let y = max(selection.logicalRect.minY - 48, 8)
        bar.setFrameOrigin(NSPoint(x: x, y: y))
        bar.makeKeyAndOrderFront(nil)
        toolbar = bar
    }

    fileprivate var currentSelection: CaptureSelection? { selection }
    fileprivate var currentHover: WindowHit? { hoverWindow }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class OverlayView: NSView {
    weak var controller: CaptureOverlayController?
    var screenFrame: ScreenFrame?

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let screenFrame else { return }
        let ctx = NSGraphicsContext.current?.cgContext
        let nsImage = NSImage(cgImage: screenFrame.image, size: bounds.size)
        nsImage.draw(in: bounds)

        NSColor.black.withAlphaComponent(0.5).setFill()
        bounds.fill()

        if let sel = controller?.currentSelection, sel.screenID == screenFrame.screenID {
            let local = convertFromGlobal(sel.logicalRect)
            nsImage.draw(in: local, from: local, operation: .copy, fraction: 1)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: local)
            path.lineWidth = 2
            path.stroke()
            let label = "\(Int(sel.logicalRect.width * screenFrame.scale)) × \(Int(sel.logicalRect.height * screenFrame.scale))"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .backgroundColor: NSColor.black.withAlphaComponent(0.6),
            ]
            (label as NSString).draw(at: CGPoint(x: local.minX + 4, y: local.maxY - 18), withAttributes: attrs)
        } else if let hover = controller?.currentHover {
            let local = convertFromGlobal(hover.logicalBounds)
            if bounds.intersects(local) {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                local.fill()
                NSColor.controlAccentColor.setStroke()
                let path = NSBezierPath(rect: local)
                path.lineWidth = 2
                path.stroke()
            }
        }
        _ = ctx
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
        controller?.mouseDown(at: global(from: convert(event.locationInWindow, from: nil)))
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

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller?.cancel() // Esc
        case 36, 76: controller?.commitCopy() // Return
        case 8 where event.modifierFlags.contains(.command): controller?.commitCopy() // ⌘C
        case 1 where event.modifierFlags.contains(.command): controller?.commitSave() // ⌘S
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class CaptureToolbar: NSPanel {
    private weak var controller: CaptureOverlayController?

    init(controller: CaptureOverlayController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 8

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        stack.addArrangedSubview(button("复制", #selector(copyAction)))
        stack.addArrangedSubview(button("保存", #selector(saveAction)))
        stack.addArrangedSubview(button("贴图", #selector(pinAction)))
        stack.addArrangedSubview(button("关闭", #selector(closeAction)))
        contentView = blur
    }

    private func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        return b
    }

    @objc private func copyAction() { controller?.commitCopy() }
    @objc private func saveAction() { controller?.commitSave() }
    @objc private func pinAction() { controller?.commitPin() }
    @objc private func closeAction() { controller?.cancel() }
}

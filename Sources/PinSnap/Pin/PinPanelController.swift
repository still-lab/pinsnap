import AppKit
import Foundation

@MainActor
public final class PinPanelController: NSObject, NSWindowDelegate {
    private let item: PinItem
    private let imageURL: URL
    private weak var store: PinStore?
    private var panel: NSPanel!
    private var imageView: PinContentView!
    private var currentScale: CGFloat
    private var currentAlpha: CGFloat

    init(item: PinItem, imageURL: URL, store: PinStore) {
        self.item = item
        self.imageURL = imageURL
        self.store = store
        self.currentScale = item.scale
        self.currentAlpha = item.alpha
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
        panel.contentView = imageView
        panel.alphaValue = item.alpha
        panel.ignoresMouseEvents = item.ignoresMouse

        self.panel = panel
        self.imageView = imageView

        let mag = NSMagnificationGestureRecognizer(target: self, action: #selector(onMagnify(_:)))
        imageView.addGestureRecognizer(mag)

        let menu = NSMenu()
        menu.addItem(withTitle: "复制", action: #selector(copyImage), keyEquivalent: "")
        menu.addItem(withTitle: "保存…", action: #selector(saveImage), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "穿透", action: #selector(toggleClickThrough), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "关闭", action: #selector(closePin), keyEquivalent: "")
        menu.addItem(withTitle: "销毁", action: #selector(destroyPin), keyEquivalent: "")
        for menuItem in menu.items { menuItem.target = self }
        imageView.menu = menu
    }

    func show() {
        panel.setFrame(item.frame, display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    func setClickThrough(_ enabled: Bool) {
        panel.ignoresMouseEvents = enabled
    }

    @objc private func onMagnify(_ g: NSMagnificationGestureRecognizer) {
        currentScale = max(0.2, min(4, currentScale * (1 + g.magnification)))
        g.magnification = 0
        var f = panel.frame
        let base = item.frame.size
        let newSize = NSSize(width: base.width * currentScale, height: base.height * currentScale)
        let center = CGPoint(x: f.midX, y: f.midY)
        f.size = newSize
        f.origin = CGPoint(x: center.x - newSize.width / 2, y: center.y - newSize.height / 2)
        panel.setFrame(f, display: true)
        imageView.frame = NSRect(origin: .zero, size: newSize)
    }

    /// 双击：复制到剪贴板并销毁贴图。
    private func copyAndDestroy() {
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
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        if p.runModal() == .OK, let url = p.url {
            try? ImageExporter().save(img, to: url, format: .png)
        }
    }

    @objc private func toggleClickThrough() {
        let next = !panel.ignoresMouseEvents
        try? store?.setClickThrough(id: item.id, enabled: next)
        Toast.shared.show(next ? "穿透已开" : "穿透已关")
    }

    @objc private func closePin() {
        try? store?.close(id: item.id)
    }

    @objc private func destroyPin() {
        try? store?.destroy(id: item.id)
    }

    public func windowWillClose(_ notification: Notification) {
        store?.panelDidClose(id: item.id)
    }

    public func windowDidMove(_ notification: Notification) {
        store?.updateFrame(id: item.id, frame: panel.frame)
    }
}

/// 可拖动；双击复制并销毁。
private final class PinContentView: NSImageView {
    var onDoubleClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        // 交给窗口拖动
        super.mouseDown(with: event)
    }
}

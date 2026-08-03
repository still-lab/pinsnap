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
    /// 创建时逻辑尺寸（scale=1），滚轮/捏合相对此基准。
    private let baseSize: NSSize

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

        let mag = NSMagnificationGestureRecognizer(target: self, action: #selector(onMagnify(_:)))
        imageView.addGestureRecognizer(mag)

        let menu = NSMenu()
        menu.addItem(withTitle: "复制", action: #selector(copyImage), keyEquivalent: "")
        menu.addItem(withTitle: "保存…", action: #selector(saveImage), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "穿透", action: #selector(toggleClickThrough), keyEquivalent: "")
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

    func applyAlpha(_ alpha: CGFloat) {
        currentAlpha = alpha
        panel.alphaValue = alpha
    }

    @objc private func onMagnify(_ g: NSMagnificationGestureRecognizer) {
        applyScale(currentScale * (1 + g.magnification), anchorInWindow: nil)
        g.magnification = 0
    }

    /// 滚轮缩放；⌃+滚轮调透明度（UI_SPEC §4.1）。
    private func handleScroll(_ event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }

        if event.modifierFlags.contains(.control) {
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

    @objc private func setOpacityFromMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        currentAlpha = value
        panel.alphaValue = value
        store?.updateAlpha(id: item.id, alpha: value)
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

/// 可拖动；双击复制并销毁；滚轮缩放 / ⌃滚轮透明度。
private final class PinContentView: NSImageView {
    var onDoubleClick: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        // 交给窗口拖动
        super.mouseDown(with: event)
    }
}

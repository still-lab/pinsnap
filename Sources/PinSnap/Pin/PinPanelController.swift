import AppKit
import Foundation

@MainActor
public final class PinPanelController: NSObject, NSWindowDelegate {
    private let item: PinItem
    private let imageURL: URL
    private weak var store: PinStore?
    private var panel: NSPanel!
    private var imageView: NSImageView!
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
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: item.frame.size))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSImage(contentsOf: imageURL)
        imageView.wantsLayer = true
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
        for item in menu.items { item.target = self }
        imageView.menu = menu
    }

    func show() {
        panel.setFrame(item.frame, display: true)
        panel.orderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFront(nil) } else { panel.orderOut(nil) }
    }

    func setClickThrough(_ enabled: Bool) {
        panel.ignoresMouseEvents = enabled
    }

    @objc private func onMagnify(_ g: NSMagnificationGestureRecognizer) {
        currentScale = max(0.2, min(4, currentScale * (1 + g.magnification)))
        g.magnification = 0
        var f = panel.frame
        let newSize = NSSize(width: item.frame.width * currentScale, height: item.frame.height * currentScale)
        f.size = newSize
        panel.setFrame(f, display: true)
        imageView.frame = NSRect(origin: .zero, size: newSize)
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
        if next {
            Toast.shared.show("穿透已开")
        } else {
            Toast.shared.show("穿透已关")
        }
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
}

/// 让 scrollWheel 到达 controller：用自定义 view
extension PinPanelController {
    func installScrollForwarder() {
        // imageView already receives events via panel content
    }
}

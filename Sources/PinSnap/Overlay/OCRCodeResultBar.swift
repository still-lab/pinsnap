import AppKit
import Foundation

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

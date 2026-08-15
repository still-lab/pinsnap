import AppKit
import Foundation
import os

public enum PinSnapLog {
    public static let subsystem = "app.pinsnap.macos"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let pin = Logger(subsystem: subsystem, category: "pin")
    public static let store = Logger(subsystem: subsystem, category: "store")
}

public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

@MainActor
public final class Toast {
    public static let shared = Toast()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    /// 屏幕底部居中的轻提示，约 1.2s 自动消失。
    /// 菜单栏 App（.accessory）下用 nonactivating 浮层，不改 activation policy，避免抢焦点。
    public func show(_ text: String) {
        hideWorkItem?.cancel()

        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 34),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let chrome = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 220, height: 34))
            chrome.material = .hudWindow
            chrome.blendingMode = .withinWindow
            chrome.state = .active
            chrome.wantsLayer = true
            chrome.layer?.cornerRadius = 8
            chrome.layer?.masksToBounds = true
            chrome.autoresizingMask = [.width, .height]
            p.contentView = chrome

            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 12, weight: .medium)
            l.textColor = .labelColor
            l.alignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            chrome.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 12),
                l.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -12),
                l.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),
            ])
            label = l
            panel = p
        }

        guard let panel, let label else { return }
        label.stringValue = text
        let width = min(360, max(180, label.intrinsicContentSize.width + 28))
        let height: CGFloat = 34
        let screen = NSScreen.main ?? NSScreen.screens.first
        let x = (screen?.frame.midX ?? 400) - width / 2
        let y = (screen?.visibleFrame.minY ?? 40) + 80
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

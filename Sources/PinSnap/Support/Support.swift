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
    private var window: NSPanel?

    private init() {}

    public func show(_ text: String) {
        window?.orderOut(nil)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        label.frame = box.bounds.insetBy(dx: 0, dy: 8)
        box.addSubview(label)
        panel.contentView = box
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - 100, y: screen.visibleFrame.minY + 48))
        }
        panel.orderFront(nil)
        window = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.window?.orderOut(nil)
        }
    }
}

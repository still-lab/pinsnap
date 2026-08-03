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

    private init() {}

    /// 不再弹出 HUD；需要时可改回实现。成功/失败改走静默或日志。
    public func show(_ text: String) {
        PinSnapLog.app.debug("toast suppressed: \(text, privacy: .public)")
    }
}

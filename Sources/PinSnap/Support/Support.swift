import Foundation
import os

public enum PinSnapLog {
    public static let subsystem = "app.pinsnap.macos"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let pin = Logger(subsystem: subsystem, category: "pin")
    public static let store = Logger(subsystem: subsystem, category: "store")
}

/// 原子写文件，避免会话 meta 半写入。
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

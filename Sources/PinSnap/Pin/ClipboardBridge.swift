import AppKit
import CoreGraphics
import Foundation

public enum ClipboardContent: Sendable {
    case image(CGImage)
    case textRendered(CGImage)
    case colorCard(CGImage, hex: String)
}

public enum ClipboardBridgeError: Error, LocalizedError, Sendable {
    case empty
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .empty: return "剪贴板为空"
        case .unsupported: return "当前剪贴板内容无法贴图"
        }
    }
}

/// 剪贴板 → 可贴图像。优先级：图像 → 图片文件 → 颜色 → 文本。
/// REQ: P-04, P-05, P-06, P-07
public protocol ClipboardBridgeProtocol: Sendable {
    func resolve() throws -> ClipboardContent
}

public struct ClipboardBridge: ClipboardBridgeProtocol {
    public init() {}

    public func resolve() throws -> ClipboardContent {
        // M2–M3: NSPasteboard
        throw ClipboardBridgeError.empty
    }
}

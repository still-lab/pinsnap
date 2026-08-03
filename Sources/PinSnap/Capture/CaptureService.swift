import Foundation

/// 截帧服务。唯一允许深度使用 ScreenCaptureKit 的入口。
/// REQ: C-01–C-03
public protocol CaptureServiceProtocol: Sendable {
    func captureStillFrames() async throws -> [ScreenFrame]
}

public enum CaptureError: Error, LocalizedError, Sendable {
    case permissionDenied
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "需要屏幕录制权限才能截图"
        case .cancelled: return "已取消"
        case .failed(let message): return message
        }
    }
}

public struct CaptureService: CaptureServiceProtocol {
    public init() {}

    public func captureStillFrames() async throws -> [ScreenFrame] {
        // M1: ScreenCaptureKit / SCScreenshotManager
        throw CaptureError.failed("未实现：M1 CaptureService")
    }
}

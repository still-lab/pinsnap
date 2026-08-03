import AppKit
import Foundation

/// 截图遮罩面板契约。实现落在 M1。
/// REQ: C-01, C-06
@MainActor
public protocol CaptureOverlayHosting: AnyObject {
    func present(frames: [ScreenFrame], geometry: ScreenGeometryProtocol)
    func dismiss()
}

public enum CaptureOverlayOutcome: Sendable {
    case cancelled
    case selected(CaptureSelection)
}

/// 占位：真正 UI 为 NSPanel 全屏覆盖。
@MainActor
public final class CaptureOverlayController: CaptureOverlayHosting {
    public var onFinish: ((CaptureOverlayOutcome) -> Void)?

    public init() {}

    public func present(frames: [ScreenFrame], geometry: ScreenGeometryProtocol) {
        // M1
    }

    public func dismiss() {
        // M1
    }
}

import Foundation

/// 截图会话状态。见 docs/ARCHITECTURE.md
public enum CaptureSessionState: Equatable, Sendable {
    case idle
    case preparing
    case capturing
    /// 长截：用户手动滚动，定时采帧。
    case scrollCapturing
    case stitching
    case annotating
    case committing
}

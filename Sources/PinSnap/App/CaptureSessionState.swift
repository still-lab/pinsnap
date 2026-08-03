import Foundation

/// 截图会话状态。见 docs/ARCHITECTURE.md
public enum CaptureSessionState: Equatable, Sendable {
    case idle
    case preparing
    case capturing
    case annotating
    case committing
}

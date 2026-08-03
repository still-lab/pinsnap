import CoreGraphics
import Foundation

/// 窗口级命中（非 AX 元素）。REQ: C-02
public protocol WindowTrackerProtocol: Sendable {
    func hits(at globalPoint: CGPoint) -> [WindowHit]
}

public struct WindowTracker: WindowTrackerProtocol {
    public init() {}

    public func hits(at globalPoint: CGPoint) -> [WindowHit] {
        // M1: CGWindowListCopyWindowInfo，过滤自身 Overlay
        []
    }
}

import CoreGraphics
import Foundation

/// 遮罩拖拽状态：拖过阈值 → 区域截图；单击 → 窗口吸附。
public struct OverlayDragSession: Equatable, Sendable {
    public var dragStart: CGPoint?
    public var isDraggingRegion = false
    public var pendingWindowBounds: CGRect?

    public var dragThreshold: CGFloat = 4

    public init() {}

    public mutating func mouseDown(at point: CGPoint, windowBounds: CGRect?) {
        dragStart = point
        isDraggingRegion = false
        pendingWindowBounds = windowBounds
    }

    public mutating func mouseDragged(at point: CGPoint) -> CGRect? {
        guard let start = dragStart else { return nil }
        let dx = abs(point.x - start.x)
        let dy = abs(point.y - start.y)
        if !isDraggingRegion, dx >= dragThreshold || dy >= dragThreshold {
            isDraggingRegion = true
            pendingWindowBounds = nil
        }
        guard isDraggingRegion else { return nil }
        return CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
    }

    public enum MouseUpResult: Equatable, Sendable {
        case region(CGRect)
        case window(CGRect)
        case none
    }

    public mutating func mouseUp(at point: CGPoint) -> MouseUpResult {
        defer { reset() }
        // 部分路径可能收不到 mouseDragged，抬起时再判一次阈值
        if let start = dragStart {
            let dx = abs(point.x - start.x)
            let dy = abs(point.y - start.y)
            if dx >= dragThreshold || dy >= dragThreshold {
                isDraggingRegion = true
                pendingWindowBounds = nil
            }
        }
        if isDraggingRegion {
            guard let rect = mouseDragged(at: point), rect.width >= 2, rect.height >= 2 else {
                return .none
            }
            return .region(rect)
        }
        if let bounds = pendingWindowBounds {
            return .window(bounds)
        }
        return .none
    }

    public mutating func reset() {
        dragStart = nil
        isDraggingRegion = false
        pendingWindowBounds = nil
    }
}

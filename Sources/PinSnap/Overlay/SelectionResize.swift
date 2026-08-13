import AppKit
import CoreGraphics
import Foundation

/// 选区边缘 / 四角拖拽缩放。
public enum SelectionResizeHandle: Equatable, Sendable {
    case n, s, e, w
    case ne, nw, se, sw
}

public enum SelectionResize {
    public static let grabThickness: CGFloat = 6
    public static let minSize = CGSize(width: 16, height: 16)

    public static func hitTest(point: CGPoint, rect: CGRect, threshold: CGFloat = grabThickness) -> SelectionResizeHandle? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let outer = rect.insetBy(dx: -threshold, dy: -threshold)
        guard outer.contains(point) else { return nil }

        let nearL = abs(point.x - rect.minX) <= threshold
        let nearR = abs(point.x - rect.maxX) <= threshold
        let nearB = abs(point.y - rect.minY) <= threshold
        let nearT = abs(point.y - rect.maxY) <= threshold
        let inX = point.x >= rect.minX - threshold && point.x <= rect.maxX + threshold
        let inY = point.y >= rect.minY - threshold && point.y <= rect.maxY + threshold

        if nearT, nearL { return .nw }
        if nearT, nearR { return .ne }
        if nearB, nearL { return .sw }
        if nearB, nearR { return .se }
        if nearT, inX { return .n }
        if nearB, inX { return .s }
        if nearL, inY { return .w }
        if nearR, inY { return .e }
        return nil
    }

    public static func cursor(for handle: SelectionResizeHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch handle {
            case .n: return .frameResize(position: .top, directions: [.inward, .outward])
            case .s: return .frameResize(position: .bottom, directions: [.inward, .outward])
            case .e: return .frameResize(position: .right, directions: [.inward, .outward])
            case .w: return .frameResize(position: .left, directions: [.inward, .outward])
            case .ne: return .frameResize(position: .topRight, directions: [.inward, .outward])
            case .nw: return .frameResize(position: .topLeft, directions: [.inward, .outward])
            case .se: return .frameResize(position: .bottomRight, directions: [.inward, .outward])
            case .sw: return .frameResize(position: .bottomLeft, directions: [.inward, .outward])
            }
        }
        switch handle {
        case .n, .s: return .resizeUpDown
        case .e, .w: return .resizeLeftRight
        case .nw, .se, .ne, .sw: return .crosshair
        }
    }

    /// `translation` = 当前鼠标 − 按下点（全局逻辑坐标）。
    public static func resizedRect(
        from origin: CGRect,
        handle: SelectionResizeHandle,
        translation: CGVector,
        bounds: CGRect,
        minSize: CGSize = minSize
    ) -> CGRect {
        var minX = origin.minX
        var maxX = origin.maxX
        var minY = origin.minY
        var maxY = origin.maxY

        switch handle {
        case .n, .ne, .nw:
            maxY = origin.maxY + translation.dy
        case .s, .se, .sw:
            minY = origin.minY + translation.dy
        case .e, .w:
            break
        }

        switch handle {
        case .e, .ne, .se:
            maxX = origin.maxX + translation.dx
        case .w, .nw, .sw:
            minX = origin.minX + translation.dx
        case .n, .s:
            break
        }

        // 最小尺寸：越过对边时钉住
        if maxX - minX < minSize.width {
            switch handle {
            case .e, .ne, .se:
                maxX = minX + minSize.width
            case .w, .nw, .sw:
                minX = maxX - minSize.width
            default:
                break
            }
        }
        if maxY - minY < minSize.height {
            switch handle {
            case .n, .ne, .nw:
                maxY = minY + minSize.height
            case .s, .se, .sw:
                minY = maxY - minSize.height
            default:
                break
            }
        }

        // 限制在屏幕内
        minX = max(minX, bounds.minX)
        maxX = min(maxX, bounds.maxX)
        minY = max(minY, bounds.minY)
        maxY = min(maxY, bounds.maxY)

        if maxX - minX < minSize.width {
            if handle == .w || handle == .nw || handle == .sw {
                minX = max(bounds.minX, maxX - minSize.width)
            } else {
                maxX = min(bounds.maxX, minX + minSize.width)
            }
        }
        if maxY - minY < minSize.height {
            if handle == .s || handle == .se || handle == .sw {
                minY = max(bounds.minY, maxY - minSize.height)
            } else {
                maxY = min(bounds.maxY, minY + minSize.height)
            }
        }

        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}

import AppKit
import CoreGraphics
import Foundation

/// 多屏几何：逻辑点 ↔ 像素。v1.0 选区不跨屏。
/// REQ: C-04
public protocol ScreenGeometryProtocol: Sendable {
    func screens() -> [ScreenDescriptor]
    func screen(containing point: CGPoint) -> ScreenDescriptor?
    func pixelRect(for selection: CaptureSelection) -> CGRect
}

public struct ScreenDescriptor: Equatable, Sendable {
    public var id: ScreenID
    public var logicalFrame: CGRect
    public var scale: CGFloat

    public init(id: ScreenID, logicalFrame: CGRect, scale: CGFloat) {
        self.id = id
        self.logicalFrame = logicalFrame
        self.scale = scale
    }
}

public struct ScreenGeometry: ScreenGeometryProtocol {
    public init() {}

    public func screens() -> [ScreenDescriptor] {
        // M1: 从 NSScreen 构建；注意 frame 与 backingScaleFactor
        []
    }

    public func screen(containing point: CGPoint) -> ScreenDescriptor? {
        screens().first { $0.logicalFrame.contains(point) }
    }

    public func pixelRect(for selection: CaptureSelection) -> CGRect {
        guard let screen = screens().first(where: { $0.id == selection.screenID }) else {
            return .null
        }
        let originInScreen = CGPoint(
            x: selection.logicalRect.minX - screen.logicalFrame.minX,
            y: selection.logicalRect.minY - screen.logicalFrame.minY
        )
        return CGRect(
            x: originInScreen.x * screen.scale,
            y: originInScreen.y * screen.scale,
            width: selection.logicalRect.width * screen.scale,
            height: selection.logicalRect.height * screen.scale
        )
    }
}

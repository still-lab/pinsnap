import AppKit
import CoreGraphics
import Foundation

/// 多屏几何：逻辑点 ↔ 像素。v1.0 选区不跨屏。
/// REQ: C-04
public protocol ScreenGeometryProtocol: Sendable {
    func screens() -> [ScreenDescriptor]
    func screen(containing point: CGPoint) -> ScreenDescriptor?
    func screen(id: ScreenID) -> ScreenDescriptor?
    func clampToSingleScreen(_ rect: CGRect) -> CaptureSelection?
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
        NSScreen.screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return ScreenDescriptor(
                id: ScreenID(rawValue: num.uint32Value),
                logicalFrame: screen.frame,
                scale: screen.backingScaleFactor
            )
        }
    }

    public func screen(containing point: CGPoint) -> ScreenDescriptor? {
        screens().first { $0.logicalFrame.contains(point) }
            ?? screens().min(by: { dist($0.logicalFrame, point) < dist($1.logicalFrame, point) })
    }

    public func screen(id: ScreenID) -> ScreenDescriptor? {
        screens().first { $0.id == id }
    }

    public func clampToSingleScreen(_ rect: CGRect) -> CaptureSelection? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = screen(containing: center) else { return nil }
        let clamped = rect.intersection(screen.logicalFrame)
        guard clamped.width >= 2, clamped.height >= 2 else { return nil }
        return CaptureSelection(screenID: screen.id, logicalRect: clamped)
    }

    public func pixelRect(for selection: CaptureSelection) -> CGRect {
        guard let screen = screen(id: selection.screenID) else { return .null }
        let originInScreen = CGPoint(
            x: selection.logicalRect.minX - screen.logicalFrame.minX,
            y: selection.logicalRect.minY - screen.logicalFrame.minY
        )
        // Cocoa Y-up vs image Y-down handled at crop time; pixel size:
        return CGRect(
            x: originInScreen.x * screen.scale,
            y: originInScreen.y * screen.scale,
            width: selection.logicalRect.width * screen.scale,
            height: selection.logicalRect.height * screen.scale
        )
    }

    private func dist(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

import CoreGraphics
import Foundation

/// 显示器标识。
public struct ScreenID: Hashable, Codable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

/// 单屏静止帧。
public struct ScreenFrame: @unchecked Sendable {
    public var screenID: ScreenID
    public var logicalBounds: CGRect
    public var scale: CGFloat
    public var image: CGImage

    public init(screenID: ScreenID, logicalBounds: CGRect, scale: CGFloat, image: CGImage) {
        self.screenID = screenID
        self.logicalBounds = logicalBounds
        self.scale = scale
        self.image = image
    }
}

/// 用户框选（全局逻辑点；v1.0 限制在单屏内）。
/// REQ: C-01, C-04
public struct CaptureSelection: Equatable, Sendable {
    public var screenID: ScreenID
    public var logicalRect: CGRect

    public init(screenID: ScreenID, logicalRect: CGRect) {
        self.screenID = screenID
        self.logicalRect = logicalRect
    }
}

public struct WindowHit: Equatable, Sendable {
    public var windowID: UInt32
    public var logicalBounds: CGRect
    public var name: String

    public init(windowID: UInt32, logicalBounds: CGRect, name: String) {
        self.windowID = windowID
        self.logicalBounds = logicalBounds
        self.name = name
    }
}

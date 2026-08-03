import CoreGraphics
import Foundation

/// 一行识别结果。`normalizedRect` 为 Vision 坐标：相对整图 0…1，原点在左下。
public struct OCRLine: Sendable, Equatable {
    public var text: String
    public var normalizedRect: CGRect

    public init(text: String, normalizedRect: CGRect) {
        self.text = text
        self.normalizedRect = normalizedRect
    }
}

public struct OCRResult: Sendable, Equatable {
    public var lines: [OCRLine]

    public init(lines: [OCRLine] = []) {
        self.lines = lines
    }

    public var isEmpty: Bool { lines.isEmpty }
}

/// Vision 归一化框 → 选区逻辑点（AppKit，原点左下）。
public enum OCRGeometry {
    public static func logicalRect(
        normalized: CGRect,
        imagePixelSize: CGSize,
        scale: CGFloat
    ) -> CGRect {
        let px = CGRect(
            x: normalized.minX * imagePixelSize.width,
            y: normalized.minY * imagePixelSize.height,
            width: normalized.width * imagePixelSize.width,
            height: normalized.height * imagePixelSize.height
        )
        return CGRect(
            x: px.minX / scale,
            y: px.minY / scale,
            width: px.width / scale,
            height: px.height / scale
        )
    }
}

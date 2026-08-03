import CoreGraphics
import Foundation

/// v1.3 长截图：多帧垂直拼接（手动滚采集后合成）。
public enum ScrollStitcher {
    public static func stitchVertically(_ images: [CGImage], overlapHint: Int = 80) -> CGImage? {
        guard let first = images.first else { return nil }
        if images.count == 1 { return first }
        let width = first.width
        var totalHeight = first.height
        var offsets: [Int] = [0]
        for i in 1..<images.count {
            let overlap = estimateOverlap(images[i - 1], images[i], hint: overlapHint)
            let advance = images[i].height - overlap
            offsets.append(offsets.last! + advance)
            totalHeight = offsets.last! + images[i].height
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for (idx, img) in images.enumerated() {
            let y = totalHeight - offsets[idx] - img.height
            ctx.draw(img, in: CGRect(x: 0, y: y, width: img.width, height: img.height))
        }
        return ctx.makeImage()
    }

    private static func estimateOverlap(_ a: CGImage, _ b: CGImage, hint: Int) -> Int {
        // Simple heuristic: use hint clamped to image sizes. Full NCC can replace later.
        min(hint, a.height / 3, b.height / 3)
    }
}

/// AX 元素吸附占位（v1.2）。REQ: C-18
public enum AccessibilitySnap {
    public static var isEnabled = false

    public static func elementFrameAtPoint(_ point: CGPoint) -> CGRect? {
        guard isEnabled else { return nil }
        // Full AXUIElement implementation in v1.2
        return nil
    }
}

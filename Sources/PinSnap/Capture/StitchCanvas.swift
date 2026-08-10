import CoreGraphics
import Foundation

/// 段式拼接画布。append / trimBottom 均为 O(1)~O(strip)；flatten 为 O(总面积)，仅在提交时调用一次。
/// 坐标系：CGImage top-left origin（y=0 在顶部），与 ScrollStitcher 一致。
public final class StitchCanvas: @unchecked Sendable {
    public let width: Int
    public private(set) var height: Int = 0

    private struct Segment {
        let image: CGImage
        /// 距画布顶部的像素偏移（CGImage top-left origin）。
        let yTop: Int
        let xLeft: Int
    }

    private var segments: [Segment] = []

    public init(width: Int) {
        self.width = width
    }

    /// 在画布底部追加一条带。O(strip area)。
    public func appendBottom(_ strip: CGImage, driftX: Int = 0) {
        segments.append(Segment(image: strip, yTop: height, xLeft: driftX))
        height += strip.height
    }

    /// 裁掉画布底部 `pixels` 像素（上滑回退）。平均 O(1)。
    public func trimBottom(_ pixels: Int) {
        guard pixels > 0, !segments.isEmpty else { return }
        var remaining = pixels
        while remaining > 0, !segments.isEmpty {
            let last = segments[segments.count - 1]
            if last.image.height <= remaining {
                remaining -= last.image.height
                segments.removeLast()
            } else {
                // 部分裁切：保留 segment 顶部，去掉底部
                let keep = last.image.height - remaining
                if let cropped = last.image.cropping(
                    to: CGRect(x: 0, y: 0, width: last.image.width, height: keep).integral
                ) {
                    segments[segments.count - 1] = Segment(
                        image: cropped, yTop: last.yTop, xLeft: last.xLeft
                    )
                }
                remaining = 0
            }
        }
        height = segments.reduce(0) { $0 + $1.image.height }
    }

    /// 裁掉首段的底部 `pixels`（sticky footer 检出后剥离首帧页脚）。O(n) for yTop 调整，仅调一次。
    public func trimFirstSegmentBottom(_ pixels: Int) {
        guard pixels > 0, !segments.isEmpty else { return }
        let first = segments[0]
        let keep = first.image.height - pixels
        guard keep > 0 else { return }
        guard let cropped = first.image.cropping(
            to: CGRect(x: 0, y: 0, width: first.image.width, height: keep).integral
        ) else { return }
        segments[0] = Segment(image: cropped, yTop: 0, xLeft: first.xLeft)
        for i in 1..<segments.count {
            let s = segments[i]
            segments[i] = Segment(image: s.image, yTop: s.yTop - pixels, xLeft: s.xLeft)
        }
        height -= pixels
    }

    /// 画布底部是否已与待接条带相同（防来回滚重叠）。
    public func bottomMatches(_ strip: CGImage, threshold: Double = 8) -> Bool {
        guard let last = segments.last else { return false }
        guard last.image.width == strip.width,
              strip.height > 0,
              last.image.height >= strip.height
        else { return false }
        let y = last.image.height - strip.height
        guard let bottom = last.image.cropping(
            to: CGRect(x: 0, y: y, width: last.image.width, height: strip.height).integral
        ) else { return false }
        return !ScrollStitcher.looksDifferent(bottom, strip, threshold: threshold)
    }

    /// 条带顶部 `rows` 行是否已出现在画布底部（advance 估大时的典型重叠）。
    public func bottomMatchesStripTop(_ strip: CGImage, rows: Int, threshold: Double = 10) -> Bool {
        let h = min(rows, strip.height)
        guard h > 0, let last = segments.last, last.image.height >= h, last.image.width == strip.width
        else { return false }
        let botY = last.image.height - h
        guard let bottom = last.image.cropping(
            to: CGRect(x: 0, y: botY, width: last.image.width, height: h).integral
        ),
        let top = strip.cropping(
            to: CGRect(x: 0, y: 0, width: strip.width, height: h).integral
        )
        else { return false }
        return !ScrollStitcher.looksDifferent(bottom, top, threshold: threshold)
    }

    /// 画布底部 image（最后一个 segment 的完整图像），用于帧间匹配。
    public func bottomImage() -> CGImage? {
        segments.last?.image
    }

    /// 全分辨率合成。O(总面积)，仅在提交时调用。
    public func flatten(maxHeight: Int = StitchCanvas.maxOutputHeight) -> CGImage? {
        let h = min(height, maxHeight)
        guard h > 0, width > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for seg in segments {
            // CGImage top-origin y → CGContext bottom-origin y
            let cgY = h - seg.yTop - seg.image.height
            if cgY >= 0 {
                ctx.draw(seg.image, in: CGRect(
                    x: seg.xLeft, y: cgY,
                    width: seg.image.width, height: seg.image.height
                ))
            } else {
                // 超出 maxHeight：裁掉 segment 底部，只画能放下的部分
                let visibleH = h - seg.yTop
                if visibleH > 0 {
                    let cropFromTop = seg.image.height - visibleH
                    if let cropped = seg.image.cropping(
                        to: CGRect(x: 0, y: cropFromTop, width: seg.image.width, height: visibleH).integral
                    ) {
                        ctx.draw(cropped, in: CGRect(
                            x: seg.xLeft, y: 0,
                            width: cropped.width, height: cropped.height
                        ))
                    }
                }
            }
        }
        return ctx.makeImage()
    }

    /// 降采样预览，用于实时侧栏显示。O(预览面积)。
    public func makePreview(maxHeight: Int = 800) -> CGImage? {
        guard height > 0, width > 0 else { return nil }
        let scale = min(1.0, CGFloat(maxHeight) / CGFloat(height))
        let pw = max(1, Int((CGFloat(width) * scale).rounded()))
        let ph = max(1, Int((CGFloat(height) * scale).rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pw, height: ph,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        for seg in segments {
            let drawH = Int((CGFloat(seg.image.height) * scale).rounded())
            let drawY_top = Int((CGFloat(seg.yTop) * scale).rounded())
            // top-origin → bottom-origin
            let cgY = ph - drawY_top - drawH
            let drawX = Int((CGFloat(seg.xLeft) * scale).rounded())
            let drawW = Int((CGFloat(seg.image.width) * scale).rounded())
            if cgY + drawH > 0 {
                ctx.draw(seg.image, in: CGRect(
                    x: drawX, y: max(0, cgY),
                    width: drawW, height: min(drawH, ph - max(0, cgY))
                ))
            }
        }
        return ctx.makeImage()
    }

    public var segmentCount: Int { segments.count }

    // MARK: - Constants

    public static let maxOutputHeight = 65_536
}

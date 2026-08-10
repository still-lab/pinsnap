import CoreGraphics
import Foundation

/// iShot 式滚动拼接：特征行 `sameArr` 测 advance + 条带拼接（非整帧叠绘）。
public final class ScrollStitchSession: @unchecked Sendable {

    public struct AppendResult: Sendable {
        public var preview: CGImage?
        public var lastFrame: CGImage
        public var acceptedFrames: [CGImage]
        public var totalAdvance: Int
        public var remainder: [CGImage]
        public var didChange: Bool
        public var hitLimit: Bool
        public var didGrow: Bool

        public init(
            preview: CGImage?,
            lastFrame: CGImage,
            acceptedFrames: [CGImage],
            totalAdvance: Int,
            remainder: [CGImage],
            didChange: Bool,
            hitLimit: Bool,
            didGrow: Bool
        ) {
            self.preview = preview
            self.lastFrame = lastFrame
            self.acceptedFrames = acceptedFrames
            self.totalAdvance = totalAdvance
            self.remainder = remainder
            self.didChange = didChange
            self.hitLimit = hitLimit
            self.didGrow = didGrow
        }
    }

    /// 侧栏高度用；预览像素来自 `makeFullImage` / `makePreviewImage`。
    public private(set) var canvas: StitchCanvas
    public var lastFrame: CGImage { frames[frames.count - 1] }
    public private(set) var totalAdvance: Int = 0
    public var acceptedCount: Int { max(0, frames.count - 1) }
    public var frameCount: Int { frames.count }
    public let width: Int

    /// iShot 帧数组
    private var frames: [CGImage] = []
    /// 各帧顶边相对画布顶的像素偏移
    private var offsets: [Int] = []

    public init(firstFrame: CGImage, detectSticky: Bool = false) {
        _ = detectSticky // iShot 不做 sticky；框选避开固定栏
        self.width = firstFrame.width
        self.frames = [firstFrame]
        self.offsets = [0]
        self.canvas = StitchCanvas(width: firstFrame.width)
        self.canvas.appendBottom(firstFrame)
    }

    /// 单帧入口（对齐 iShot 每次 `screenShotsAtScrollScreenshots` 进一帧）。
    @discardableResult
    public func append(_ frame: CGImage) -> AppendResult {
        append(incoming: [frame])
    }

    public func append(incoming: [CGImage]) -> AppendResult {
        let countBefore = frames.count
        guard !incoming.isEmpty else {
            return makeResult(accepted: [], advance: 0, remainder: [], didChange: false, didGrow: false)
        }

        var accepted: [CGImage] = []
        var advanceSum = 0
        var didChange = false
        let framesIn = incoming.compactMap { ScrollStitcher.fitted($0, toMatch: lastFrame) }
        guard !framesIn.isEmpty else {
            return makeResult(accepted: [], advance: 0, remainder: [], didChange: false, didGrow: false)
        }

        var i = 0
        while i < framesIn.count {
            if hitLimit() { break }
            let frame = framesIn[i]

            // 相同帧不保留（iShot isEqual 路径）
            if !ScrollStitcher.looksDifferent(lastFrame, frame, threshold: 2.5) {
                i += 1
                continue
            }

            // 只接受向下推进（事件层已忽略 Δ≥0；此处不再做上滑回退）
            guard let advance = resolveDownAdvance(for: frame), advance >= ScrollStitcher.minAdvancePixels else {
                // 匹配失败：丢弃该帧，继续尝试后续（不桥接堆积）
                i += 1
                continue
            }

            let newTop = (offsets.last ?? 0) + advance
            if contentHeight() + advance > StitchCanvas.maxOutputHeight
                || frames.count >= ScrollStitcher.maxFrames {
                break
            }

            frames.append(frame)
            offsets.append(newTop)
            totalAdvance += advance
            accepted.append(frame)
            advanceSum += advance
            didChange = true
            // 预览高度：只追加新条带（侧栏用）；最终/侧栏像素图走 drawScrollView
            if let strip = ScrollStitcher.contentStrip(frame: frame, advance: advance) {
                canvas.appendBottom(strip)
            }
            i += 1
        }

        let grew = frames.count > countBefore
        return makeResult(
            accepted: accepted,
            advance: advanceSum,
            remainder: [],
            didChange: didChange,
            didGrow: grew
        )
    }

    /// 最终图：条带拼接（非整帧叠绘）。
    public func makeFullImage() -> CGImage? {
        drawScrollView(maxHeight: StitchCanvas.maxOutputHeight)
    }

    /// 侧栏预览：同算法，限制高度以免卡顿。
    public func makePreviewImage(maxHeight: Int = 2400) -> CGImage? {
        guard let full = drawScrollView(maxHeight: maxHeight) else { return nil }
        let maxW = 280
        guard full.width > maxW else { return full }
        let scale = CGFloat(maxW) / CGFloat(full.width)
        let h = max(1, Int((CGFloat(full.height) * scale).rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: maxW, height: h,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return full }
        ctx.interpolationQuality = .medium
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: maxW, height: h))
        return ctx.makeImage() ?? full
    }

    // MARK: - Private

    /// 三帧滑动窗口（只向下）。
    private func resolveDownAdvance(for frame: CGImage) -> Int? {
        if let d = ScrollStitcher.measureAdvance(previous: lastFrame, next: frame) {
            return d
        }
        guard frames.count >= 2 else { return nil }
        let prev2 = frames[frames.count - 2]
        let prev1 = frames[frames.count - 1]
        if ScrollStitcher.measureAdvance(previous: prev2, next: prev1) != nil,
           let d = ScrollStitcher.measureAdvance(previous: prev2, next: frame) {
            let removedAdv = offsets[offsets.count - 1] - offsets[offsets.count - 2]
            frames.removeLast()
            offsets.removeLast()
            totalAdvance = max(0, totalAdvance - max(0, removedAdv))
            rebuildCanvasHeight()
            return d
        }
        return nil
    }

    /// 首帧整幅；后续只贴底部 advance 条带（对齐 iShot 去粘性后只留新内容），接缝 10px。
    private func drawScrollView(maxHeight: Int) -> CGImage? {
        guard let first = frames.first else { return nil }
        let w = first.width
        let totalH = min(maxHeight, contentHeight())
        guard totalH > 0 else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: totalH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let blend = 10
        let firstH = min(first.height, totalH)
        if firstH > 0,
           let piece = first.height == firstH
            ? first
            : first.cropping(to: CGRect(x: 0, y: 0, width: w, height: firstH).integral) {
            ctx.setAlpha(1)
            ctx.draw(piece, in: CGRect(x: 0, y: totalH - firstH, width: w, height: firstH))
        }

        for idx in 1..<frames.count {
            let adv = offsets[idx] - offsets[idx - 1]
            // 条带顶边紧接已拼内容底：firstH + sum(advances before this)
            let yTop = first.height + offsets[idx - 1]
            guard adv > 0, yTop < totalH,
                  let strip = ScrollStitcher.contentStrip(frame: frames[idx], advance: adv)
            else { continue }
            let drawH = min(strip.height, totalH - yTop)
            guard drawH > 0,
                  let piece = strip.height == drawH
                    ? strip
                    : strip.cropping(to: CGRect(x: 0, y: 0, width: w, height: drawH).integral)
            else { continue }

            let seam = min(blend, drawH)
            if seam > 0,
               let topBand = piece.cropping(to: CGRect(x: 0, y: 0, width: w, height: seam).integral) {
                for row in 0..<seam {
                    guard let line = topBand.cropping(
                        to: CGRect(x: 0, y: row, width: w, height: 1).integral
                    ) else { continue }
                    let t = Double(row) / Double(max(seam - 1, 1))
                    let cgY = totalH - yTop - row - 1
                    ctx.setAlpha(CGFloat(t))
                    ctx.draw(line, in: CGRect(x: 0, y: cgY, width: w, height: 1))
                }
            }
            if drawH > seam,
               let rest = piece.cropping(
                to: CGRect(x: 0, y: seam, width: w, height: drawH - seam).integral
               ) {
                let cgY = totalH - yTop - drawH
                ctx.setAlpha(1)
                ctx.draw(rest, in: CGRect(x: 0, y: cgY, width: w, height: drawH - seam))
            }
        }
        ctx.setAlpha(1)
        return ctx.makeImage()
    }

    /// 条带模型：首帧高 + 累计 advance（`offsets.last`）。
    private func contentHeight() -> Int {
        guard let first = frames.first, let off = offsets.last else { return 0 }
        return first.height + off
    }

    private func hitLimit() -> Bool {
        contentHeight() >= StitchCanvas.maxOutputHeight || frames.count >= ScrollStitcher.maxFrames
    }

    private func rebuildCanvasHeight() {
        canvas = StitchCanvas(width: width)
        guard let first = frames.first else { return }
        canvas.appendBottom(first)
        for idx in 1..<frames.count {
            let adv = offsets[idx] - offsets[idx - 1]
            if adv > 0, let strip = ScrollStitcher.contentStrip(frame: frames[idx], advance: adv) {
                canvas.appendBottom(strip)
            }
        }
    }

    private func makeResult(
        accepted: [CGImage],
        advance: Int,
        remainder: [CGImage],
        didChange: Bool,
        didGrow: Bool
    ) -> AppendResult {
        AppendResult(
            preview: makePreviewImage(),
            lastFrame: lastFrame,
            acceptedFrames: accepted,
            totalAdvance: advance,
            remainder: remainder,
            didChange: didChange,
            hitLimit: hitLimit(),
            didGrow: didGrow
        )
    }
}

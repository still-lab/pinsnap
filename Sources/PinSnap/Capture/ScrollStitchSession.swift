import CoreGraphics
import Foundation

/// iShot 式滚动拼接会话：帧数组 + Y 偏移数组 + 全宽 SAD 对齐 + 最终 10px 渐变合成。
public final class ScrollStitchSession: @unchecked Sendable {

    public struct AppendResult: Sendable {
        public var preview: CGImage?
        public var lastFrame: CGImage
        public var acceptedFrames: [CGImage]
        public var totalAdvance: Int
        public var remainder: [CGImage]
        public var didChange: Bool
        public var hitLimit: Bool
        /// 本次是否让帧数组增长（idle 结束判定用）
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

    /// 兼容侧栏：用轻量 canvas 只表示当前总高度 / 预览来源。
    public private(set) var canvas: StitchCanvas
    public var lastFrame: CGImage { frames[frames.count - 1] }
    public private(set) var totalAdvance: Int = 0
    public var acceptedCount: Int { max(0, frames.count - 1) }
    public var frameCount: Int { frames.count }
    public let width: Int

    /// 帧数组（iShot 0xe28）
    private var frames: [CGImage] = []
    /// 各帧顶边距画布顶的像素偏移（iShot 0xe30）
    private var offsets: [Int] = []

    public init(firstFrame: CGImage, detectSticky: Bool = false) {
        _ = detectSticky
        self.width = firstFrame.width
        self.frames = [firstFrame]
        self.offsets = [0]
        self.canvas = StitchCanvas(width: firstFrame.width)
        self.canvas.appendBottom(firstFrame)
    }

    public func append(incoming: [CGImage]) -> AppendResult {
        let countBefore = frames.count
        guard !incoming.isEmpty else {
            return makeResult(
                accepted: [], advance: 0, remainder: [],
                didChange: false, didGrow: false
            )
        }

        var accepted: [CGImage] = []
        var advanceSum = 0
        var didChange = false
        var framesIn = incoming.compactMap { ScrollStitcher.fitted($0, toMatch: lastFrame) }
        guard !framesIn.isEmpty else {
            return makeResult(
                accepted: [], advance: 0, remainder: [],
                didChange: false, didGrow: false
            )
        }

        var remainder: [CGImage] = []
        var i = 0
        while i < framesIn.count {
            if hitLimit() { break }
            let frame = framesIn[i]

            // 相同帧不保留
            if !ScrollStitcher.looksDifferent(lastFrame, frame, threshold: 2.5) {
                i += 1
                continue
            }

            // 三帧滑动窗口：先比 last↔frame；失败则试 frames[n-2]↔last 与 last↔frame 链路
            guard let advance = resolveAdvance(for: frame) else {
                remainder = Array(framesIn[i...])
                break
            }

            if advance < 0 {
                // 上滑：回退偏移（裁逻辑高度）
                let up = -advance
                let maxTrim = max(0, contentHeight() - frame.height)
                let trim = min(up, maxTrim)
                if trim > 0, frames.count > 1 {
                    frames.removeLast()
                    offsets.removeLast()
                    totalAdvance = max(0, totalAdvance - trim)
                    rebuildCanvasPreview()
                    didChange = true
                }
                // 同步当前视口帧
                if frames.isEmpty {
                    frames = [frame]
                    offsets = [0]
                } else {
                    frames[frames.count - 1] = frame
                }
                didChange = true
                i += 1
                continue
            }

            let newTop = (offsets.last ?? 0) + advance
            if newTop + frame.height > StitchCanvas.maxOutputHeight
                || frames.count >= ScrollStitcher.maxFrames {
                break
            }

            frames.append(frame)
            offsets.append(newTop)
            totalAdvance += advance
            accepted.append(frame)
            advanceSum += advance
            didChange = true
            appendStripToPreviewCanvas(frame: frame, advance: advance)
            i += 1
        }

        let grew = frames.count > countBefore
        return makeResult(
            accepted: accepted,
            advance: advanceSum,
            remainder: remainder.isEmpty && i >= framesIn.count ? [] : (remainder.isEmpty ? Array(framesIn[i...]) : remainder),
            didChange: didChange,
            didGrow: grew
        )
    }

    /// iShot drawScrollView：按偏移绘制整帧，接缝约 10px alpha 渐变。
    public func makeFullImage() -> CGImage? {
        guard let first = frames.first else { return nil }
        let w = first.width
        let totalH = min(StitchCanvas.maxOutputHeight, contentHeight())
        guard totalH > 0 else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: totalH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let blend = 10
        for (idx, frame) in frames.enumerated() {
            let yTop = offsets[idx]
            let drawH = min(frame.height, totalH - yTop)
            guard drawH > 0,
                  let piece = frame.height == drawH
                    ? frame
                    : frame.cropping(to: CGRect(x: 0, y: 0, width: w, height: drawH).integral)
            else { continue }

            // CGContext：y=0 在底；画布顶 = totalH
            if idx == 0 || blend <= 0 || yTop == 0 {
                let cgY = totalH - yTop - drawH
                ctx.setAlpha(1)
                ctx.draw(piece, in: CGRect(x: 0, y: cgY, width: w, height: drawH))
                continue
            }

            let seam = min(blend, drawH)
            // 顶部 seam 行：fraction 0→1（越往下越实）
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
        ScrollStitcher.clearGrayCache()
        return ctx.makeImage()
    }

    // MARK: - Private

    private func resolveAdvance(for frame: CGImage) -> Int? {
        // 直接相邻匹配
        if let d = ScrollStitcher.signedScrollDelta(previous: lastFrame, next: frame) {
            return d
        }
        // 三帧窗口：若存在 F[n-2], 尝试 F[n-1]↔F[n] 已失败时，看 F[n-2]↔F[n-1] 是否仍成立并丢弃坏帧
        guard frames.count >= 2 else { return nil }
        let prev2 = frames[frames.count - 2]
        let prev1 = frames[frames.count - 1]
        if ScrollStitcher.signedScrollDelta(previous: prev2, next: prev1) != nil,
           let d = ScrollStitcher.signedScrollDelta(previous: prev1, next: frame) {
            return d
        }
        // 后移：直接把新帧接到 prev2（跳过损坏的中间态）
        if let d = ScrollStitcher.signedScrollDelta(previous: prev2, next: frame) {
            // 回退一帧再接
            if frames.count > 1 {
                let removedAdv = offsets[offsets.count - 1] - offsets[offsets.count - 2]
                frames.removeLast()
                offsets.removeLast()
                totalAdvance = max(0, totalAdvance - max(0, removedAdv))
                rebuildCanvasPreview()
            }
            return d
        }
        return nil
    }

    private func contentHeight() -> Int {
        guard let last = frames.last, let off = offsets.last else { return 0 }
        return off + last.height
    }

    private func hitLimit() -> Bool {
        contentHeight() >= StitchCanvas.maxOutputHeight || frames.count >= ScrollStitcher.maxFrames
    }

    private func appendStripToPreviewCanvas(frame: CGImage, advance: Int) {
        if let strip = ScrollStitcher.contentStrip(frame: frame, advance: advance) {
            if !canvas.bottomMatches(strip) {
                var use = advance
                var s = strip
                let lead = min(16, max(4, use / 4))
                while use >= ScrollStitcher.minAdvancePixels,
                      canvas.bottomMatchesStripTop(s, rows: lead, threshold: 10),
                      let nextStrip = ScrollStitcher.contentStrip(frame: frame, advance: use - lead) {
                    use -= lead
                    s = nextStrip
                }
                if use >= ScrollStitcher.minAdvancePixels, !canvas.bottomMatches(s) {
                    canvas.appendBottom(s)
                }
            }
        }
    }

    private func rebuildCanvasPreview() {
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
            preview: canvas.makePreview(),
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

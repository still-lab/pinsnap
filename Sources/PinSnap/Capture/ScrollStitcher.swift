import CoreGraphics
import Foundation
import Vision

/// v1.3 长截图垂直拼接（对齐 iShot：全宽 BT.601 + SAD 重叠搜索）。
public enum ScrollStitcher {
    public static let maxOutputHeight = 65_536
    public static let maxFrames = 240
    public static let minAdvancePixels = 8
    public static let defaultOverlapHint = 80
    public static let maxHorizontalDrift = 6
    public static let minVisionConfidence: Float = 0.4
    /// 最佳与次佳推进分差过小则拒接（防误匹配）。
    public static let minScoreMargin: Double = 3.0
    /// 行间平均绝对差低于此视为静止 chrome。
    public static let chromeRowMAD: Double = 3.5
    /// 真机截图像素抖动更大，接受阈值需高于噪声夹具。
    public static let maxAcceptMAD: Double = 40

    public struct Alignment: Equatable, Sendable {
        public var overlap: Int
        public var driftX: Int
        /// 越低越好（MAD）。
        public var score: Double

        public init(overlap: Int, driftX: Int, score: Double) {
            self.overlap = overlap
            self.driftX = driftX
            self.score = score
        }
    }

    /// 静止条带区域（sticky header / footer），用于输出层去重。
    public struct StickyRegions: Sendable {
        public let top: Int
        public let bottom: Int

        public init(top: Int = 0, bottom: Int = 0) {
            self.top = top
            self.bottom = bottom
        }

        public var hasSticky: Bool { top > 0 || bottom > 0 }
    }

    // MARK: - Gray image cache

    /// 缓存条目：持有 CGImage 强引用，防止对象释放后地址被新 CGImage 复用导致缓存命中错误。
    private final class GrayCacheEntry {
        let image: CGImage
        let gray: GrayImage
        init(image: CGImage, gray: GrayImage) {
            self.image = image
            self.gray = gray
        }
    }

    private static let grayCacheLock = NSLock()
    private static var grayCache: [(key: Int, entry: GrayCacheEntry)] = []
    private static let grayCacheMaxSize = 12

    /// 带缓存的灰度转换。帧间匹配频繁复用同一 CGImage，缓存可避免每帧重复 RGBA→灰度。
    /// entry 持有 CGImage 强引用 → 对象不会释放 → 指针地址不会被复用 → 缓存键可靠。
    private static func cachedGrayTopLeft(_ image: CGImage) -> GrayImage? {
        let key = Int(bitPattern: Unmanaged.passUnretained(image).toOpaque())
        grayCacheLock.lock()
        defer { grayCacheLock.unlock() }

        if let idx = grayCache.firstIndex(where: { $0.key == key }) {
            let entry = grayCache.remove(at: idx)
            grayCache.append(entry) // MRU → tail
            return entry.entry.gray
        }

        guard let gray = grayTopLeft(image) else { return nil }
        let entry = GrayCacheEntry(image: image, gray: gray)
        grayCache.append((key: key, entry: entry))
        while grayCache.count > grayCacheMaxSize {
            grayCache.removeFirst()
        }
        return gray
    }

    /// 清空灰度缓存（会话结束时调用，释放内存）。
    public static func clearGrayCache() {
        grayCacheLock.lock()
        grayCache.removeAll()
        grayCacheLock.unlock()
    }

    // MARK: - Sticky detection

    /// 检测两帧间静止的顶/底条带（sticky header / footer）。
    /// 复用 edgeChromeMask 逻辑；返回 top/bottom 像素高度。
    public static func detectSticky(previous: CGImage, next: CGImage) -> StickyRegions {
        guard let prev = cachedGrayTopLeft(previous),
              let nxt = cachedGrayTopLeft(next),
              prev.width == nxt.width,
              prev.height == nxt.height,
              prev.height > 48
        else { return StickyRegions() }

        let mask = edgeChromeMask(prev: prev, next: nxt)
        let h = prev.height
        let edge = max(16, h / 3)

        var topH = 0
        while topH < edge, mask[topH] {
            topH += 1
        }

        var bottomH = 0
        var y = h - 1
        while y >= h - edge, y >= 0, mask[y] {
            bottomH += 1
            y -= 1
        }

        return StickyRegions(top: topH, bottom: bottomH)
    }

    /// 从帧中裁出新内容条带（排除 sticky 顶/底区域）。
    /// `advance` = 新内容像素数；条带高度 = min(advance, contentHeight)。
    /// CGImage y=0 top；新内容在内容区底部（即 stickyBottom 上方）。
    public static func contentStrip(
        frame: CGImage,
        advance: Int,
        stickyTop: Int = 0,
        stickyBottom: Int = 0
    ) -> CGImage? {
        let contentH = frame.height - stickyTop - stickyBottom
        guard contentH > 0, advance > 0 else { return nil }
        let added = min(advance, contentH)
        let srcY = frame.height - stickyBottom - added
        guard srcY >= stickyTop else { return nil }
        return frame.cropping(
            to: CGRect(x: 0, y: srcY, width: frame.width, height: added).integral
        )
    }

    // MARK: - Public API

    public static func filterAdvances(
        _ images: [CGImage],
        overlapHint: Int = defaultOverlapHint
    ) -> [CGImage] {
        guard let first = images.first else { return [] }
        var result: [CGImage] = [first]
        for img in images.dropFirst() {
            guard result.count < maxFrames else { break }
            if shouldAppend(previous: result[result.count - 1], next: img, overlapHint: overlapHint) {
                result.append(img)
            }
        }
        return result
    }

    public static func stitchVertically(
        _ images: [CGImage],
        overlapHint: Int = defaultOverlapHint,
        maxHorizontalDrift: Int = maxHorizontalDrift
    ) -> CGImage? {
        let frames = filterAdvances(images, overlapHint: overlapHint)
        guard let first = frames.first else { return nil }
        if frames.count == 1 { return first }

        let width = first.width
        var offsets: [Int] = [0]
        var drifts: [Int] = [0]

        for i in 1..<frames.count {
            let alignment = estimateAlignment(
                frames[i - 1],
                frames[i],
                hint: overlapHint,
                maxDriftX: maxHorizontalDrift,
                fast: false
            )
            let advance = max(minAdvancePixels, frames[i].height - alignment.overlap)
            offsets.append(offsets[offsets.count - 1] + advance)
            drifts.append(alignment.driftX)
        }

        var totalHeight = offsets[offsets.count - 1] + frames[frames.count - 1].height
        if totalHeight > maxOutputHeight { totalHeight = maxOutputHeight }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        for (idx, img) in frames.enumerated() {
            let y = totalHeight - offsets[idx] - img.height
            let dx = drifts[idx]
            ctx.draw(img, in: CGRect(x: dx, y: y, width: img.width, height: img.height))
        }
        return ctx.makeImage()
    }

    /// iShot 式推进量：全宽 BT.601 灰度，重叠区逐像素 SAD 均值最小者为 advance。
    /// `hint` 保留 API，不用作搜索上限。
    public static func measureAdvance(
        previous: CGImage,
        next: CGImage,
        hint: Int = 0
    ) -> Int? {
        guard previous.width == next.width,
              previous.height == next.height,
              previous.height > 48
        else { return nil }
        _ = hint

        // 过宽时等比缩宽（保持高度比），加速全宽扫描；advance 再按比例还原
        let maxW = 360
        let workPrev: CGImage
        let workNext: CGImage
        let scale: CGFloat
        if previous.width > maxW {
            guard let p = rescaleImage(previous, toWidth: maxW),
                  let n = rescaleImage(next, toWidth: maxW)
            else { return nil }
            workPrev = p
            workNext = n
            scale = CGFloat(previous.height) / CGFloat(p.height)
        } else {
            workPrev = previous
            workNext = next
            scale = 1
        }

        guard let prev = grayTopLeft(workPrev),
              let nxt = grayTopLeft(workNext),
              prev.width == nxt.width,
              prev.height == nxt.height
        else { return nil }

        let h = prev.height
        let w = prev.width
        let minAdv = max(minAdvancePixels, h / 100)
        // 至少保留约 25% 重叠，对应 iShot 类「大重叠带」拼接
        let minOverlap = max(32, h / 4)
        let maxAdv = h - minOverlap
        guard minAdv <= maxAdv else { return nil }

        // 横向可隔点采样；纵向全覆盖重叠带（对齐「全宽」精神，控制耗时）
        let stepX = max(1, w / 180)

        var bestAdv = 0
        var bestScore = Double.infinity
        var secondScore = Double.infinity

        for advance in minAdv...maxAdv {
            let overlap = h - advance
            var sad: Int64 = 0
            var count = 0
            var y = 0
            while y < overlap {
                let py = advance + y
                var x = 0
                while x < w {
                    sad += Int64(abs(Int(prev.pixel(x, py)) - Int(nxt.pixel(x, y))))
                    count += 1
                    x += stepX
                }
                y += 1
            }
            guard count > 0 else { continue }
            let score = Double(sad) / Double(count)
            if score < bestScore {
                secondScore = bestScore
                bestScore = score
                bestAdv = advance
            } else if score < secondScore {
                secondScore = score
            }
        }

        // 匹配过差或与次优分不清则拒接（防重复纹理假匹配）
        guard bestAdv >= minAdv, bestScore < 28 else { return nil }
        if secondScore.isFinite, (secondScore - bestScore) < 0.8, bestScore > 8 {
            return nil
        }

        let full = max(minAdvancePixels, Int((CGFloat(bestAdv) * scale).rounded()))
        return min(full, previous.height - max(32, previous.height / 4))
    }

    public struct ChainAppendResult: Sendable {
        public var canvas: CGImage
        public var lastFrame: CGImage
        public var acceptedFrames: [CGImage]
        public var totalAdvance: Int
        /// 尚未接到 `lastFrame` 上的尾部桥接帧，调用方应保留。
        public var remainder: [CGImage]
        /// 含上滑裁底 / 同步 last，即使未增长也要写回。
        public var didChange: Bool

        public var acceptedCount: Int { acceptedFrames.count }

        public init(
            canvas: CGImage,
            lastFrame: CGImage,
            acceptedFrames: [CGImage],
            totalAdvance: Int,
            remainder: [CGImage],
            didChange: Bool
        ) {
            self.canvas = canvas
            self.lastFrame = lastFrame
            self.acceptedFrames = acceptedFrames
            self.totalAdvance = totalAdvance
            self.remainder = remainder
            self.didChange = didChange
        }
    }

    /// 按顺序把 `incoming` 接到画布上；中间帧可作桥。
    /// 仅下滑增长；上滑则裁掉对应底部并同步 last，避免来回滚重叠。
    public static func chainAppend(
        canvas: CGImage,
        lastFrame: CGImage,
        incoming: [CGImage]
    ) -> ChainAppendResult? {
        guard !incoming.isEmpty else { return nil }

        var ref = lastFrame
        var cv = canvas
        var accepted: [CGImage] = []
        var totalAdvance = 0
        var didChange = false
        var frames = incoming.compactMap { fitted($0, toMatch: lastFrame) }
        guard !frames.isEmpty else { return nil }

        // 队头失步：找第一帧能下滑接到 ref 的
        if signedScrollDelta(previous: ref, next: frames[0]).map({ $0 > 0 }) != true,
           let idx = frames.indices.first(where: {
               guard looksDifferent(ref, frames[$0], threshold: 2.5) else { return false }
               guard let d = signedScrollDelta(previous: ref, next: frames[$0]), d >= minAdvancePixels
               else { return false }
               return true
           }),
           idx > 0
        {
            frames = Array(frames[idx...])
        }

        var remainder: [CGImage] = []
        var i = 0
        while i < frames.count {
            let frame = frames[i]
            if !looksDifferent(ref, frame, threshold: 2.5) {
                i += 1
                continue
            }
            guard let delta = signedScrollDelta(previous: ref, next: frame) else {
                remainder = Array(frames[i...])
                break
            }
            if delta < 0 {
                let up = -delta
                let maxTrim = max(0, cv.height - frame.height)
                let trimBy = min(up, maxTrim)
                if trimBy > 0, let trimmedCanvas = trimBottom(cv, by: trimBy) {
                    cv = trimmedCanvas
                }
                ref = frame
                didChange = true
                i += 1
                continue
            }
            if let next = appendByAdvance(canvas: cv, nextFrame: frame, advance: delta),
               next.height > cv.height {
                cv = next
                ref = frame
                accepted.append(frame)
                totalAdvance += delta
                didChange = true
                i += 1
                continue
            }
            if isLikelyDuplicateAppend(canvas: cv, next: frame, advance: delta) {
                ref = frame
                didChange = true
                i += 1
                continue
            }
            remainder = Array(frames[i...])
            break
        }

        if !didChange {
            return ChainAppendResult(
                canvas: canvas,
                lastFrame: lastFrame,
                acceptedFrames: [],
                totalAdvance: 0,
                remainder: remainder.isEmpty ? frames : remainder,
                didChange: false
            )
        }
        return ChainAppendResult(
            canvas: cv,
            lastFrame: ref,
            acceptedFrames: accepted,
            totalAdvance: totalAdvance,
            remainder: remainder,
            didChange: true
        )
    }

    private static func isLikelyDuplicateAppend(
        canvas: CGImage,
        next: CGImage,
        advance: Int
    ) -> Bool {
        let added = min(advance, next.height - 1)
        guard added > 0 else { return false }
        let srcY = next.height - added
        guard let strip = next.cropping(
            to: CGRect(x: 0, y: srcY, width: next.width, height: added).integral
        ) else { return false }
        return canvasBottomMatches(canvas, strip: strip)
    }

    static func fitted(_ image: CGImage, toMatch ref: CGImage) -> CGImage? {
        if image.width == ref.width, image.height == ref.height { return image }
        guard let scaled = rescaleImage(image, toWidth: ref.width),
              scaled.height == ref.height
        else { return nil }
        return scaled
    }

    private static func probeMAD(
        prev: GrayImage,
        next: GrayImage,
        probeY: Int,
        probeH: Int,
        advance: Int,
        stepX: Int
    ) -> Double {
        let ny = probeY - advance
        if ny < 0 { return .infinity }
        var sum = 0.0
        var n = 0.0
        for dy in 0..<probeH {
            let py = probeY + dy
            let qy = ny + dy
            var x = 0
            while x < prev.width {
                sum += abs(Double(prev.pixel(x, py)) - Double(next.pixel(x, qy)))
                n += 1
                x += stepX
            }
        }
        return sum / max(n, 1)
    }

    /// 按实测推进拼接：从下一帧底部取 `advance` 像素接到画布下。
    /// 若条带已与画布底部相同（滚轮回摆/重复帧），拒绝拼接以防重叠。
    /// `stickyBottom`：若有 sticky 页脚，从页脚上方取内容条带（输出层去重）。
    public static func appendByAdvance(
        canvas: CGImage,
        nextFrame: CGImage,
        advance advancePixels: Int,
        stickyBottom: Int = 0
    ) -> CGImage? {
        guard canvas.width == nextFrame.width, advancePixels > 0 else { return nil }
        let advance = min(advancePixels, nextFrame.height - stickyBottom - 1)
        guard advance > 0 else { return nil }

        let newHeight = min(maxOutputHeight, canvas.height + advance)
        let added = newHeight - canvas.height
        guard added > 0 else { return nil }

        // CGImage.cropping：y=0 为顶；新内容在 stickyBottom 上方 → 从 height-stickyBottom-added 裁
        let srcY = nextFrame.height - stickyBottom - added
        guard srcY >= 0,
              let strip = nextFrame.cropping(
                to: CGRect(x: 0, y: srcY, width: nextFrame.width, height: added).integral
              )
        else { return nil }

        if canvasBottomMatches(canvas, strip: strip) {
            return nil
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: canvas.width, height: newHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(canvas, in: CGRect(x: 0, y: added, width: canvas.width, height: canvas.height))
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
        return ctx.makeImage()
    }

    /// 裁掉画布底部 `pixels`（上滑回退用）。CGImage y=0 为顶。
    public static func trimBottom(_ canvas: CGImage, by pixels: Int) -> CGImage? {
        guard pixels > 0, canvas.height - pixels >= 32 else { return nil }
        let keep = canvas.height - pixels
        return canvas.cropping(
            to: CGRect(x: 0, y: 0, width: canvas.width, height: keep).integral
        )
    }

    /// 内容相对上一帧的滚动方向：正=露出下方新内容（下滑），负=上滑回退。
    public static func signedScrollDelta(previous: CGImage, next: CGImage) -> Int? {
        if let down = measureAdvance(previous: previous, next: next), down >= minAdvancePixels {
            return down
        }
        if let up = measureAdvance(previous: next, next: previous), up >= minAdvancePixels {
            return -up
        }
        return nil
    }

    /// 帧质量门控：滤掉静止帧，以及 `measureAdvance` MAD/分差过差的动画中间态。
    /// 过关的帧才优先送入实时 Session；未过关但 visually 不同的可进桥接缓冲。
    public static func passesScrollFrameGate(previous: CGImage, next: CGImage) -> Bool {
        guard looksDifferent(previous, next, threshold: 2.5) else { return false }
        return signedScrollDelta(previous: previous, next: next) != nil
    }

    /// 画布底部是否已与待接条带相同（防来回滚重叠）。
    public static func canvasBottomMatches(_ canvas: CGImage, strip: CGImage, threshold: Double = 8) -> Bool {
        guard canvas.width == strip.width,
              strip.height > 0,
              canvas.height >= strip.height
        else { return false }
        let y = canvas.height - strip.height
        guard let bottom = canvas.cropping(
            to: CGRect(x: 0, y: y, width: canvas.width, height: strip.height).integral
        ) else { return false }
        return !looksDifferent(bottom, strip, threshold: threshold)
    }

    public static func append(
        canvas: CGImage,
        previousFrame: CGImage,
        nextFrame: CGImage,
        overlapHint: Int = defaultOverlapHint,
        maxHorizontalDrift: Int = maxHorizontalDrift
    ) -> CGImage? {
        guard let alignment = acceptedAlignment(
            previous: previousFrame,
            next: nextFrame,
            overlapHint: overlapHint,
            maxHorizontalDrift: maxHorizontalDrift,
            fast: false
        ) else { return nil }
        return append(canvas: canvas, nextFrame: nextFrame, alignment: alignment)
    }

    /// 使用已算好的对齐，避免实时环里重复跑昂贵匹配。
    public static func append(
        canvas: CGImage,
        nextFrame: CGImage,
        alignment: Alignment
    ) -> CGImage? {
        guard canvas.width == nextFrame.width else { return nil }

        let advance = nextFrame.height - alignment.overlap
        let newHeight = min(maxOutputHeight, canvas.height + advance)
        let added = newHeight - canvas.height
        guard added > 0 else { return nil }

        let drift = alignment.driftX
        let srcX = max(0, -drift)
        let dstX = max(0, drift)
        let stripW = min(nextFrame.width - srcX, canvas.width - dstX)
        // CGImage.cropping 的 y=0 是图像顶部（与 CGContext 底原点相反）。
        // 向下滚时新内容在选区底部 = 图像下部，必须从 height-added 裁。
        let srcY = nextFrame.height - added
        guard stripW > 0, srcY >= 0,
              let strip = nextFrame.cropping(
                to: CGRect(x: srcX, y: srcY, width: stripW, height: added).integral
              )
        else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: canvas.width, height: newHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(canvas, in: CGRect(x: 0, y: added, width: canvas.width, height: canvas.height))
        ctx.draw(strip, in: CGRect(x: dstX, y: 0, width: strip.width, height: strip.height))
        return ctx.makeImage()
    }

    public static func stackImages(_ images: [CGImage]) -> CGImage? {
        guard let first = images.first else { return nil }
        let width = first.width
        let totalH = images.reduce(0) { partial, img in
            let h = (img.width == width)
                ? img.height
                : Int((CGFloat(img.height) * CGFloat(width) / CGFloat(img.width)).rounded())
            return partial + max(1, h)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: totalH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var y = totalH
        for img in images {
            let draw = (img.width == width) ? img : (rescaleImage(img, toWidth: width) ?? img)
            y -= draw.height
            ctx.draw(draw, in: CGRect(x: 0, y: y, width: draw.width, height: draw.height))
        }
        return ctx.makeImage()
    }

    public static func rescaleImage(_ image: CGImage, toWidth width: Int) -> CGImage? {
        guard width > 0, image.width > 0 else { return nil }
        let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)).rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    public static func shouldAppend(
        previous: CGImage,
        next: CGImage,
        overlapHint: Int = defaultOverlapHint,
        fast: Bool = false
    ) -> Bool {
        acceptedAlignment(
            previous: previous,
            next: next,
            overlapHint: overlapHint,
            maxHorizontalDrift: maxHorizontalDrift,
            fast: fast
        ) != nil
    }

    public static func looksDifferent(_ a: CGImage, _ b: CGImage, threshold: Double = 12) -> Bool {
        guard let ga = cachedGrayTopLeft(a), let gb = cachedGrayTopLeft(b),
              ga.width == gb.width, ga.height == gb.height
        else { return true }
        let step = max(1, ga.width / 48)
        var sum = 0
        var count = 0
        var y = 0
        while y < ga.height {
            var x = 0
            while x < ga.width {
                sum += abs(Int(ga.pixel(x, y)) - Int(gb.pixel(x, y)))
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return true }
        return Double(sum) / Double(count) >= threshold
    }

    public static func acceptedAlignment(
        previous: CGImage,
        next: CGImage,
        overlapHint: Int = defaultOverlapHint,
        maxHorizontalDrift: Int = maxHorizontalDrift,
        fast: Bool = false
    ) -> Alignment? {
        guard previous.width == next.width,
              previous.height > 24,
              next.height > 24,
              previous.height == next.height
        else { return nil }

        if !looksDifferent(previous, next, threshold: 5) {
            return nil
        }

        let alignment = estimateAlignment(
            previous,
            next,
            hint: overlapHint,
            maxDriftX: maxHorizontalDrift,
            fast: fast
        )
        let h = next.height
        let advance = h - alignment.overlap
        let minAdv = max(minAdvancePixels, h / 40)
        // 至少保留 40% 重叠；单次推进不超过半高，避免把顶栏整段叠进去
        let minOverlap = max(48, (h * 2) / 5)
        let maxAdv = min(h - minOverlap, h / 2)
        guard alignment.score.isFinite else { return nil }
        guard alignment.score <= maxAcceptMAD else { return nil }
        guard advance >= minAdv, advance <= maxAdv else { return nil }
        return alignment
    }

    /// 对外诊断：返回最终对齐（已精修）。
    public static func estimateAlignment(
        _ a: CGImage,
        _ b: CGImage,
        hint: Int,
        maxDriftX: Int,
        fast: Bool = false
    ) -> Alignment {
        if let robust = estimateAlignmentRobust(a, b, maxDriftX: maxDriftX, fast: fast) {
            return robust
        }
        // 最后手段：Vision 单票（无共识时）
        if let vision = estimateAlignmentVision(reference: a, floating: b, maxDriftX: maxDriftX, fast: fast) {
            return vision
        }
        return Alignment(overlap: max(0, min(a.height, b.height) - hint), driftX: 0, score: .infinity)
    }

    // MARK: - Robust pipeline

    private static func estimateAlignmentRobust(
        _ previous: CGImage,
        _ next: CGImage,
        maxDriftX: Int,
        fast: Bool
    ) -> Alignment? {
        // 实时环降采样粗搜；随后必须全分辨率局部精修，否则代码/列表会错位出缝
        let maxWorkWidth = fast ? 240 : previous.width
        let scale: CGFloat
        let workPrev: CGImage
        let workNext: CGImage
        if previous.width > maxWorkWidth {
            guard let p = rescaleImage(previous, toWidth: maxWorkWidth),
                  let n = rescaleImage(next, toWidth: maxWorkWidth)
            else { return nil }
            workPrev = p
            workNext = n
            scale = CGFloat(previous.height) / CGFloat(p.height)
        } else {
            workPrev = previous
            workNext = next
            scale = 1
        }

        guard let prev = grayTopLeft(workPrev),
              let nxt = grayTopLeft(workNext),
              prev.width == nxt.width,
              prev.height == nxt.height
        else { return nil }

        let h = prev.height
        let fullH = previous.height
        let chrome = edgeChromeMask(prev: prev, next: nxt)
        let driftCap = fast ? min(2, maxDriftX) : maxDriftX

        let coarseStep = fast ? max(2, h / 100) : 1
        guard var best = matchScrollDown(
            prev: prev,
            next: nxt,
            chrome: chrome,
            maxDriftX: driftCap,
            advanceStep: coarseStep,
            sampleStride: fast ? 3 : 2
        ) else { return nil }

        best = refineLocally(
            prev: prev,
            next: nxt,
            chrome: chrome,
            around: best,
            maxDriftX: driftCap,
            radius: 4
        )
        // 分数接近时取更小推进，避免代码行重复/半截缝
        best = preferConservativeAdvance(
            prev: prev,
            next: nxt,
            chrome: chrome,
            around: best,
            maxDriftX: driftCap
        )

        // 映射回全分辨率后再精修
        if scale != 1 {
            let workAdvance = h - best.overlap
            let fullAdvance = max(minAdvancePixels, Int((CGFloat(workAdvance) * scale).rounded()))
            let fullDrift = Int((CGFloat(best.driftX) * scale).rounded())
            best = Alignment(
                overlap: max(0, fullH - fullAdvance),
                driftX: max(-maxDriftX, min(maxDriftX, fullDrift)),
                score: best.score
            )
        }

        if let fullPrev = cachedGrayTopLeft(previous),
           let fullNext = cachedGrayTopLeft(next),
           fullPrev.width == fullNext.width,
           fullPrev.height == fullNext.height
        {
            let fullChrome = edgeChromeMask(prev: fullPrev, next: fullNext)
            let refineRadius = scale != 1 ? max(10, Int(scale.rounded()) + 4) : 6
            best = refineLocally(
                prev: fullPrev,
                next: fullNext,
                chrome: fullChrome,
                around: best,
                maxDriftX: maxDriftX,
                radius: refineRadius
            )
            best = preferConservativeAdvance(
                prev: fullPrev,
                next: fullNext,
                chrome: fullChrome,
                around: best,
                maxDriftX: maxDriftX
            )
        }

        PinSnapLog.capture.info(
            "stitch profile advance=\(fullH - best.overlap) mad=\(best.score) fast=\(fast)"
        )
        return best
    }

    /// 向下滚（灰度 row0 = 顶）：`prev[advance + y] ≈ next[y]`，新内容在下一帧底部。
    private static func matchScrollDown(
        prev: GrayImage,
        next: GrayImage,
        chrome: [Bool],
        maxDriftX: Int,
        advanceStep: Int,
        sampleStride: Int
    ) -> Alignment? {
        let h = prev.height
        let minAdv = max(minAdvancePixels, h / 40)
        let maxAdv = min(h - max(48, (h * 2) / 5), h / 2)
        guard maxAdv > minAdv else { return nil }

        var best = Alignment(overlap: 0, driftX: 0, score: .infinity)
        var second = Alignment(overlap: 0, driftX: 0, score: .infinity)

        var advance = minAdv
        while advance <= maxAdv {
            for drift in -maxDriftX...maxDriftX {
                let mad = bandMAD(
                    prev: prev,
                    next: next,
                    chrome: chrome,
                    advance: advance,
                    driftX: drift,
                    sampleStride: sampleStride
                )
                if mad < best.score {
                    second = best
                    best = Alignment(overlap: h - advance, driftX: drift, score: mad)
                } else if mad < second.score {
                    second = Alignment(overlap: h - advance, driftX: drift, score: mad)
                }
            }
            advance += advanceStep
        }

        guard best.score.isFinite else { return nil }
        // 仅在匹配本身不够干净时，才用分差防误拼
        if second.score.isFinite,
           (second.score - best.score) < minScoreMargin,
           best.score > 16
        {
            return nil
        }
        return best
    }

    private static func refineLocally(
        prev: GrayImage,
        next: GrayImage,
        chrome: [Bool],
        around: Alignment,
        maxDriftX: Int,
        radius: Int
    ) -> Alignment {
        let h = prev.height
        let center = h - around.overlap
        let maxAdv = min(h - max(48, (h * 2) / 5), h / 2)
        let lo = max(minAdvancePixels, center - radius)
        let hi = min(maxAdv, center + radius)
        guard lo <= hi else { return around }
        var best = around
        for advance in lo...hi {
            for drift in max(-maxDriftX, around.driftX - 2)...min(maxDriftX, around.driftX + 2) {
                let mad = bandMAD(
                    prev: prev,
                    next: next,
                    chrome: chrome,
                    advance: advance,
                    driftX: drift,
                    sampleStride: 1
                )
                if mad < best.score {
                    best = Alignment(overlap: h - advance, driftX: drift, score: mad)
                }
            }
        }
        return best
    }

    /// 在相近 MAD 下选更小的 advance，减少「半行重复」缝。
    private static func preferConservativeAdvance(
        prev: GrayImage,
        next: GrayImage,
        chrome: [Bool],
        around: Alignment,
        maxDriftX: Int
    ) -> Alignment {
        let h = prev.height
        let center = h - around.overlap
        let minAdv = max(minAdvancePixels, h / 40)
        let lo = max(minAdv, center - 16)
        var chosen = around
        if lo >= center { return around }
        for advance in lo..<center {
            let mad = bandMAD(
                prev: prev,
                next: next,
                chrome: chrome,
                advance: advance,
                driftX: around.driftX,
                sampleStride: 1
            )
            // 允许略差，换更保守的重叠
            if mad <= around.score + 2.5 {
                chosen = Alignment(overlap: h - advance, driftX: around.driftX, score: mad)
            }
        }
        return chosen
    }

    private static func bandMAD(
        prev: GrayImage,
        next: GrayImage,
        chrome: [Bool],
        advance: Int,
        driftX: Int,
        sampleStride: Int
    ) -> Double {
        let h = prev.height
        let w = prev.width
        let overlap = h - advance
        guard overlap > 0 else { return .infinity }

        let x0 = max(0, driftX)
        let x1 = min(w, w + driftX)
        guard x1 - x0 > 8 else { return .infinity }

        var sum = 0.0
        var weight = 0.0
        let stepY = max(1, sampleStride)
        let stepX = max(1, sampleStride)

        // 灰度 row0=顶：重叠区 prev[advance..<h] ≈ next[0..<overlap]
        var y = 0
        while y < overlap {
            let py = y + advance
            let ny = y
            if chrome[py] || chrome[ny] {
                y += stepY
                continue
            }
            // 平坦行降权，但不丢弃（网页大量留白，丢弃会让匹配权重不足）
            let varP = rowVariance(prev, y: py, x0: x0, x1: x1, step: stepX)
            let varN = rowVariance(next, y: ny, x0: max(0, x0 - driftX), x1: min(w, x1 - driftX), step: stepX)
            let wRow = 0.2 + min(varP, varN) / 60.0

            var x = x0
            while x < x1 {
                let nx = x - driftX
                if nx >= 0, nx < w {
                    sum += abs(Double(prev.pixel(x, py)) - Double(next.pixel(nx, ny))) * wRow
                    weight += wRow
                }
                x += stepX
            }
            y += stepY
        }
        guard weight > 4 else { return .infinity }
        return sum / weight
    }

    private static func rowVariance(_ g: GrayImage, y: Int, x0: Int, x1: Int, step: Int) -> Double {
        var sum = 0.0
        var sum2 = 0.0
        var n = 0.0
        var x = x0
        while x < x1 {
            let v = Double(g.pixel(x, y))
            sum += v
            sum2 += v * v
            n += 1
            x += step
        }
        guard n > 2 else { return 0 }
        let mean = sum / n
        return max(0, sum2 / n - mean * mean)
    }

    /// 仅遮罩贴顶/贴底的静止条（导航栏等）。
    /// 全行静止检测会把网页留白误判成 chrome，导致真机永远拼不上。
    private static func edgeChromeMask(prev: GrayImage, next: GrayImage) -> [Bool] {
        let h = prev.height
        let w = prev.width
        var staticRow = [Bool](repeating: false, count: h)
        let step = max(1, w / 64)
        for y in 0..<h {
            var sum = 0
            var count = 0
            var x = 0
            while x < w {
                sum += abs(Int(prev.pixel(x, y)) - Int(next.pixel(x, y)))
                count += 1
                x += step
            }
            let mad = count > 0 ? Double(sum) / Double(count) : 999
            staticRow[y] = mad < chromeRowMAD
        }

        var mask = [Bool](repeating: false, count: h)
        // 顶栏（标题+筛选）常超过 h/6，放到 h/3
        let edge = max(16, h / 3)
        // 从顶向下连续静止
        var y = 0
        while y < edge, staticRow[y] {
            mask[y] = true
            y += 1
        }
        // 从底向上连续静止
        y = h - 1
        while y >= h - edge, y >= 0, staticRow[y] {
            mask[y] = true
            y -= 1
        }
        // 轻膨胀
        var dilated = mask
        for i in 0..<h where mask[i] {
            for d in -2...2 {
                let yy = i + d
                if yy >= 0, yy < h { dilated[yy] = true }
            }
        }
        return dilated
    }

    // MARK: - Vision

    private static func estimateAlignmentVision(
        reference: CGImage,
        floating: CGImage,
        maxDriftX: Int,
        fast: Bool
    ) -> Alignment? {
        let maxW = fast ? 400 : 720
        guard let (refScaled, scale) = prepareForVision(reference, maxWidth: maxW),
              let (floatScaled, _) = prepareForVision(floating, maxWidth: maxW),
              refScaled.width == floatScaled.width
        else { return nil }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floatScaled)
        let handler = VNImageRequestHandler(cgImage: refScaled, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation,
              observation.confidence >= minVisionConfidence
        else { return nil }

        let t = observation.alignmentTransform
        let tx = Int((t.tx / scale).rounded())
        let ty = Int((t.ty / scale).rounded())
        guard abs(tx) <= maxDriftX + 8 else { return nil }

        let h = min(reference.height, floating.height)
        let advance = abs(ty)
        let overlap = h - advance
        guard overlap >= minAdvancePixels else { return nil }

        let drift = max(-maxDriftX, min(maxDriftX, tx))
        // 映射到 MAD 近似量级，便于和行匹配比
        let score = Double((1 - observation.confidence) * 30)
        return Alignment(overlap: max(0, overlap), driftX: drift, score: score)
    }

    private static func prepareForVision(_ image: CGImage, maxWidth: Int) -> (CGImage, CGFloat)? {
        guard image.width > 0, image.height > 0 else { return nil }
        if image.width <= maxWidth { return (image, 1) }
        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        guard let scaled = rescaleImage(image, toWidth: maxWidth) else { return nil }
        return (scaled, scale)
    }

    // MARK: - Gray buffer (row0 = top)

    private struct GrayImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> UInt8 {
            pixels[y * width + x]
        }
    }

    private static func grayTopLeft(_ image: CGImage) -> GrayImage? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var pixels = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            let r = Double(rgba[o])
            let g = Double(rgba[o + 1])
            let b = Double(rgba[o + 2])
            // iShot literal：BT.601 0.30 / 0.59 / 0.11
            pixels[i] = UInt8(max(0, min(255, r * 0.30 + g * 0.59 + b * 0.11)))
        }
        return GrayImage(width: w, height: h, pixels: pixels)
    }
}

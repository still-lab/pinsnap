import AppKit
import CoreGraphics
import Foundation

/// 长截侧边实时预览：无包裹壳，贴选区旁；图变长时整体缩小；避开工具条。
@MainActor
final class ScrollCapturePreview: NSPanel {
    private let imageView = NSImageView()
    private let previewMaxWidth: CGFloat = 160
    private var anchorSelection: CGRect = .zero
    private var screenBounds: CGRect = .zero
    /// 需要避开的区域（通常是工具条）。
    private var avoidRect: CGRect = .null
    private var lastCanvasHeight = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: previewMaxWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver + 2
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        imageView.autoresizingMask = [.width, .height]

        let root = NSView(frame: NSRect(x: 0, y: 0, width: previewMaxWidth, height: 120))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        imageView.frame = root.bounds
        root.addSubview(imageView)
        contentView = root
    }

    /// 贴在选区旁；`avoiding` 一般为工具条 frame。
    func place(beside selection: CGRect, inScreenBounds screen: CGRect, avoiding avoid: CGRect? = nil) {
        anchorSelection = selection
        screenBounds = screen
        avoidRect = avoid?.insetBy(dx: -6, dy: -6) ?? .null
        applyLayout(
            displaySize: NSSize(width: previewMaxWidth, height: min(120, maxPreviewHeight()))
        )
        orderFrontRegardless()
    }

    func setAvoiding(_ avoid: CGRect?) {
        avoidRect = avoid?.insetBy(dx: -6, dy: -6) ?? .null
        if imageView.image != nil {
            let display = fittedDisplaySize(for: intrinsicSizeFromCurrentImage())
            applyLayout(displaySize: display)
        }
    }

    func update(preview: CGImage?) {
        guard let preview else {
            imageView.image = nil
            lastCanvasHeight = 0
            return
        }

        let scale = backingScale()
        let intrinsic = NSSize(
            width: max(1, CGFloat(preview.width) / scale),
            height: max(1, CGFloat(preview.height) / scale)
        )
        let display = fittedDisplaySize(for: intrinsic)
        let pixelW = max(1, Int((display.width * scale).rounded()))
        let pixelH = max(1, Int((display.height * scale).rounded()))
        let shown = Self.rescale(preview, width: pixelW, height: pixelH) ?? preview

        imageView.image = NSImage(
            cgImage: shown,
            size: NSSize(width: display.width, height: display.height)
        )
        applyLayout(displaySize: display)
        imageView.needsDisplay = true
        contentView?.needsDisplay = true
        lastCanvasHeight = preview.height
    }

    private func backingScale() -> CGFloat {
        max(
            NSScreen.main?.backingScaleFactor
                ?? NSScreen.screens.first(where: { $0.frame.intersects(screenBounds) })?.backingScaleFactor
                ?? 2,
            1
        )
    }

    private func intrinsicSizeFromCurrentImage() -> NSSize {
        imageView.image?.size ?? NSSize(width: previewMaxWidth, height: 120)
    }

    private func maxPreviewHeight() -> CGFloat {
        let margin: CGFloat = 8
        return max(
            60,
            min(
                screenBounds.height - margin * 2,
                max(anchorSelection.height, screenBounds.height * 0.9)
            )
        )
    }

    private func fittedDisplaySize(for intrinsic: NSSize) -> NSSize {
        let maxH = maxPreviewHeight()
        let maxW = previewMaxWidth
        let fit = min(
            maxW / max(intrinsic.width, 1),
            maxH / max(intrinsic.height, 1),
            1
        )
        return NSSize(
            width: max(40, intrinsic.width * fit),
            height: max(40, intrinsic.height * fit)
        )
    }

    private func applyLayout(displaySize: NSSize) {
        let gap: CGFloat = 8
        let margin: CGFloat = 8
        var displayW = displaySize.width
        var displayH = displaySize.height
        let sel = anchorSelection

        struct Candidate {
            var frame: CGRect
            var priority: Int
        }

        func clampToScreen(_ rect: CGRect) -> CGRect {
            var r = rect
            r.origin.x = min(max(r.minX, screenBounds.minX + margin), screenBounds.maxX - r.width - margin)
            r.origin.y = min(max(r.minY, screenBounds.minY + margin), screenBounds.maxY - r.height - margin)
            return r
        }

        func overlapsAvoid(_ rect: CGRect) -> Bool {
            guard !avoidRect.isNull, !avoidRect.isInfinite else { return false }
            return rect.intersects(avoidRect)
        }

        // 在某一侧生成若干垂直位置：顶对齐、底对齐选区、避开 avoid 上方/下方
        func sideCandidates(x: CGFloat, priorityBase: Int) -> [Candidate] {
            var list: [Candidate] = []
            var tops = [
                sel.maxY - displayH,           // 与选区顶对齐
                sel.midY - displayH / 2,       // 垂直居中
                sel.minY,                      // 底边贴选区底（常在工具条之上）
            ]
            if !avoidRect.isNull {
                // 整块放在工具条上方 / 下方
                tops.append(avoidRect.minY - gap - displayH)
                tops.append(avoidRect.maxY + gap)
            }
            for (i, y) in tops.enumerated() {
                let raw = CGRect(x: x, y: y, width: displayW, height: displayH)
                let framed = clampToScreen(raw)
                list.append(Candidate(frame: framed, priority: priorityBase + i))
            }
            return list
        }

        let rightX = sel.maxX + gap
        let leftX = sel.minX - gap - displayW
        var candidates =
            sideCandidates(x: rightX, priorityBase: 0)
            + sideCandidates(x: leftX, priorityBase: 100)

        // 若默认高度总会挡住工具条，尝试略缩高度再生成一轮
        if !avoidRect.isNull {
            let roomAbove = max(0, avoidRect.minY - margin - (screenBounds.minY + margin))
            let roomBelow = max(0, screenBounds.maxY - margin - (avoidRect.maxY + margin))
            let shrunkH = min(displayH, max(60, max(roomAbove, roomBelow) - 4))
            if shrunkH + 1 < displayH {
                let scale = shrunkH / displayH
                displayW = max(40, displayW * scale)
                displayH = shrunkH
                let rightXs = sel.maxX + gap
                let leftXs = sel.minX - gap - displayW
                candidates +=
                    sideCandidates(x: rightXs, priorityBase: 200)
                    + sideCandidates(x: leftXs, priorityBase: 300)
            }
        }

        let clear = candidates
            .filter { !overlapsAvoid($0.frame) }
            .sorted { $0.priority < $1.priority }

        let chosen: CGRect
        if let best = clear.first?.frame {
            chosen = best
        } else {
            // 全挡不住时：选与工具条相交最少的
            let leastOverlap = candidates.min { a, b in
                let ia = a.frame.intersection(avoidRect).area
                let ib = b.frame.intersection(avoidRect).area
                if ia != ib { return ia < ib }
                return a.priority < b.priority
            }?.frame
            chosen = leastOverlap ?? clampToScreen(CGRect(
                x: rightX,
                y: sel.maxY - displayH,
                width: displayW,
                height: displayH
            ))
        }

        setFrame(chosen, display: true)
        if let root = contentView {
            root.frame = NSRect(origin: .zero, size: chosen.size)
        }
        imageView.frame = NSRect(origin: .zero, size: chosen.size)
    }

    private static func rescale(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        if image.width == width, image.height == height { return image }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}

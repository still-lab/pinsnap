import AppKit
import CoreGraphics
import CoreImage
import Foundation

public enum ShapeKind: String, Codable, Sendable {
    case rect, ellipse, line, arrow, freehand, marker, eraser, text, mosaic, blur, number, highlight
}

public struct Shape: Identifiable, Codable, Sendable {
    public var id: UUID
    public var kind: ShapeKind
    public var lineWidth: CGFloat
    public var points: [CGPoint]
    public var text: String?
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(
        id: UUID = UUID(),
        kind: ShapeKind,
        lineWidth: CGFloat = 2,
        points: [CGPoint] = [],
        text: String? = nil,
        color: NSColor = .systemRed
    ) {
        self.id = id
        self.kind = kind
        self.lineWidth = lineWidth
        self.points = points
        self.text = text
        let c = color.usingColorSpace(.sRGB) ?? color
        self.red = c.redComponent
        self.green = c.greenComponent
        self.blue = c.blueComponent
        self.alpha = c.alphaComponent
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

public struct AnnotationDocument: Codable, Sendable {
    public var shapes: [Shape]
    public init(shapes: [Shape] = []) { self.shapes = shapes }
}

@MainActor
public protocol AnnotationControlling: AnyObject {
    var document: AnnotationDocument { get }
    func add(_ shape: Shape)
    func undo()
    func redo()
    func exportFlattened(base: CGImage) -> CGImage?
}

@MainActor
public final class AnnotationController: AnnotationControlling {
    public private(set) var document = AnnotationDocument()
    private var undoStack: [AnnotationDocument] = []
    private var redoStack: [AnnotationDocument] = []

    public init() {}

    public func reset() {
        document = AnnotationDocument()
        undoStack.removeAll()
        redoStack.removeAll()
    }

    public func add(_ shape: Shape) {
        undoStack.append(document)
        redoStack.removeAll()
        var next = document
        next.shapes.append(shape)
        document = next
    }

    public func replace(_ shape: Shape) {
        guard let index = document.shapes.firstIndex(where: { $0.id == shape.id }) else {
            add(shape)
            return
        }
        undoStack.append(document)
        redoStack.removeAll()
        var next = document
        next.shapes[index] = shape
        document = next
    }

    public func remove(id: UUID) {
        guard document.shapes.contains(where: { $0.id == id }) else { return }
        undoStack.append(document)
        redoStack.removeAll()
        var next = document
        next.shapes.removeAll { $0.id == id }
        document = next
    }

    /// 拖动过程中更新，不进撤销栈（开始拖动前请先 `prepareUndoCheckpoint()`）
    public func prepareUndoCheckpoint() {
        undoStack.append(document)
        redoStack.removeAll()
    }

    public func setShapeLive(_ shape: Shape) {
        guard let index = document.shapes.firstIndex(where: { $0.id == shape.id }) else { return }
        var next = document
        next.shapes[index] = shape
        document = next
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// text 的 lineWidth 即逻辑点字号。
    public static func textFont(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .medium)
    }

    public static func textSize(_ shape: Shape) -> CGSize {
        textSize(text: shape.text ?? "", fontSize: max(12, shape.lineWidth))
    }

    public static func textSize(text: String, fontSize: CGFloat) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont(size: fontSize),
            .foregroundColor: NSColor.black,
        ]
        let s = (text as NSString).size(withAttributes: attrs)
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    /// `points[0]` = 字框左下角（AppKit 坐标）。
    public static func textFrame(_ shape: Shape) -> CGRect {
        CGRect(origin: shape.points.first ?? .zero, size: textSize(shape))
    }

    public static func makeTextCGImage(
        text: String,
        color: NSColor,
        fontSize: CGFloat,
        scale: CGFloat
    ) -> CGImage? {
        let size = textSize(text: text, fontSize: fontSize)
        guard size.width > 0.5, size.height > 0.5 else { return nil }
        let pixelW = max(1, Int(ceil(size.width * scale)))
        let pixelH = max(1, Int(ceil(size.height * scale)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = nsCtx
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont(size: fontSize),
            .foregroundColor: color,
        ]
        (text as NSString).draw(in: CGRect(origin: .zero, size: size), withAttributes: attrs)
        return rep.cgImage
    }

    public func exportFlattened(base: CGImage) -> CGImage? {
        let w = base.width
        let h = base.height
        guard let annotations = Self.renderAnnotationOverlay(
            shapes: document.shapes,
            pixelWidth: w,
            pixelHeight: h,
            base: base
        ) else { return base }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(annotations, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? base
    }

    /// 仅标注层（含橡皮 destinationOut）。坐标为像素、原点左下。
    public static func renderAnnotationOverlay(
        shapes: [Shape],
        pixelWidth: Int,
        pixelHeight: Int,
        base: CGImage?
    ) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0, !shapes.isEmpty else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let annCtx = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        annCtx.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        for shape in shapes {
            drawStatic(shape, in: annCtx, canvasHeight: CGFloat(pixelHeight), base: base)
        }
        return annCtx.makeImage()
    }

    private func draw(_ shape: Shape, in ctx: CGContext, canvasHeight: CGFloat, base: CGImage?) {
        Self.drawStatic(shape, in: ctx, canvasHeight: canvasHeight, base: base)
    }

    private static func drawStatic(_ shape: Shape, in ctx: CGContext, canvasHeight: CGFloat, base: CGImage?) {
        let color = shape.nsColor.cgColor
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(shape.lineWidth)
        let pts = shape.points
        guard let first = pts.first else { return }

        switch shape.kind {
        case .rect:
            guard let last = pts.last else { return }
            let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                           width: abs(last.x - first.x), height: abs(last.y - first.y))
            ctx.stroke(r)
        case .ellipse:
            guard let last = pts.last else { return }
            let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                           width: abs(last.x - first.x), height: abs(last.y - first.y))
            ctx.strokeEllipse(in: r)
        case .line, .arrow:
            guard let last = pts.last else { return }
            ctx.move(to: first)
            ctx.addLine(to: last)
            ctx.strokePath()
            if shape.kind == .arrow {
                Self.drawArrowHead(from: first, to: last, in: ctx)
            }
        case .freehand, .marker:
            ctx.setStrokeColor(color)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: first)
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .eraser:
            // 只擦标注层像素；需不透明 stroke 才有 destinationOut 效果
            ctx.saveGState()
            ctx.setBlendMode(.destinationOut)
            ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(max(1, shape.lineWidth))
            ctx.move(to: first)
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
            ctx.restoreGState()
        case .text:
            let text = shape.text ?? ""
            guard !text.isEmpty else { return }
            let fontSize = max(12, shape.lineWidth)
            guard let cg = AnnotationController.makeTextCGImage(
                text: text,
                color: shape.nsColor,
                fontSize: fontSize,
                scale: 1
            ) else { return }
            let size = AnnotationController.textSize(text: text, fontSize: fontSize)
            ctx.draw(cg, in: CGRect(origin: first, size: size))
        case .mosaic, .blur:
            guard let base, let last = pts.last else { return }
            let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                           width: abs(last.x - first.x), height: abs(last.y - first.y)).integral
            guard let patch = Self.filteredPatch(kind: shape.kind, rectInBottomLeftPixels: r, base: base) else { return }
            ctx.draw(patch, in: r)
        case .number:
            let n = shape.text ?? "1"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.boldSystemFont(ofSize: 14),
            ]
            let diameter: CGFloat = 22
            ctx.setFillColor(shape.nsColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: first.x, y: first.y, width: diameter, height: diameter))
            let ns = NSAttributedString(string: n, attributes: attrs)
            let sz = ns.size()
            let img = NSImage(size: sz)
            img.lockFocus(); ns.draw(at: .zero); img.unlockFocus()
            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.draw(cg, in: CGRect(x: first.x + (diameter - sz.width) / 2, y: first.y + (diameter - sz.height) / 2, width: sz.width, height: sz.height))
            }
        case .highlight:
            guard let last = pts.last else { return }
            let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                           width: abs(last.x - first.x), height: abs(last.y - first.y))
            ctx.setFillColor(shape.nsColor.withAlphaComponent(0.35).cgColor)
            ctx.fill(r)
        }
    }

    private static func drawArrowHead(from: CGPoint, to: CGPoint, in ctx: CGContext) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let len: CGFloat = 12
        let a1 = angle + .pi * 0.8
        let a2 = angle - .pi * 0.8
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: to.x + cos(a1) * len, y: to.y + sin(a1) * len))
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: to.x + cos(a2) * len, y: to.y + sin(a2) * len))
        ctx.strokePath()
    }

    /// `rectInBottomLeftPixels` 与 `CGContext` 绘制坐标系一致（原点在左下）。
    /// REQ: E-008, E-009
    public static func filteredPatch(
        kind: ShapeKind,
        rectInBottomLeftPixels: CGRect,
        base: CGImage,
        mosaicBlock: CGFloat = 16,
        blurRadius: CGFloat = 8
    ) -> CGImage? {
        guard kind == .mosaic || kind == .blur else { return nil }
        guard let cropped = cropBottomLeft(base, rect: rectInBottomLeftPixels) else { return nil }
        if kind == .mosaic {
            return pixelateNearest(cropped, blockPixels: max(4, Int(mosaicBlock.rounded())))
        }
        let input = CIImage(cgImage: cropped)
        let filtered = input
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, blurRadius)])
            .cropped(to: input.extent)
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(filtered, from: input.extent)
    }

    /// 从左下原点矩形裁剪（内部转换为 CGImage 顶左坐标系）。
    public static func cropBottomLeft(_ image: CGImage, rect: CGRect) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.integral.intersection(imageBounds)
        guard r.width >= 1, r.height >= 1 else { return nil }
        let topLeft = CGRect(
            x: r.origin.x,
            y: CGFloat(image.height) - r.maxY,
            width: r.width,
            height: r.height
        ).integral
        guard topLeft.width >= 1, topLeft.height >= 1 else { return nil }
        return image.cropping(to: topLeft)
    }

    /// 近邻缩小再放大，块状马赛克（比 CIPixellate 更稳、更明显）。
    public static func pixelateNearest(_ image: CGImage, blockPixels: Int) -> CGImage? {
        let block = max(2, blockPixels)
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        let sw = max(1, w / block)
        let sh = max(1, h / block)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let smallCtx = CGContext(
            data: nil, width: sw, height: sh,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return nil }
        smallCtx.interpolationQuality = .none
        smallCtx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let small = smallCtx.makeImage() else { return nil }

        guard let bigCtx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return nil }
        bigCtx.interpolationQuality = .none
        bigCtx.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bigCtx.makeImage()
    }
}

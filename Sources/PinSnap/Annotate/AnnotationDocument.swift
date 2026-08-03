import AppKit
import CoreGraphics
import CoreImage
import Foundation

public enum ShapeKind: String, Codable, Sendable {
    case rect, ellipse, line, arrow, freehand, text, mosaic, blur, number, highlight
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
    private let ci = CIContext()

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
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }

        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        for shape in document.shapes {
            draw(shape, in: ctx, canvasHeight: CGFloat(h), base: base)
        }
        return ctx.makeImage() ?? base
    }

    private func draw(_ shape: Shape, in ctx: CGContext, canvasHeight: CGFloat, base: CGImage) {
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
                drawArrowHead(from: first, to: last, in: ctx)
            }
        case .freehand:
            ctx.move(to: first)
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
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
            guard let last = pts.last else { return }
            let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                           width: abs(last.x - first.x), height: abs(last.y - first.y)).integral
            applyFilter(kind: shape.kind, rect: r, base: base, ctx: ctx)
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

    private func drawArrowHead(from: CGPoint, to: CGPoint, in ctx: CGContext) {
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

    private func applyFilter(kind: ShapeKind, rect: CGRect, base: CGImage, ctx: CGContext) {
        guard let cropped = base.cropping(to: rect) else { return }
        var ci = CIImage(cgImage: cropped)
        if kind == .mosaic {
            ci = ci.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 12])
        } else {
            ci = ci.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 8])
        }
        if let out = ciContextCreateCGImage(ci, from: ci.extent) {
            ctx.draw(out, in: rect)
        }
    }

    private func ciContextCreateCGImage(_ image: CIImage, from rect: CGRect) -> CGImage? {
        ci.createCGImage(image, from: rect)
    }
}

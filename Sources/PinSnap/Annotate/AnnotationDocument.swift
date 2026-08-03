import CoreGraphics
import Foundation

public enum ShapeKind: String, Codable, Sendable {
    case rect, ellipse, line, arrow, freehand, text, mosaic, blur
}

public struct Shape: Identifiable, Codable, Sendable {
    public var id: UUID
    public var kind: ShapeKind
    public var lineWidth: CGFloat
    public var points: [CGPoint]
    public var text: String?

    public init(
        id: UUID = UUID(),
        kind: ShapeKind,
        lineWidth: CGFloat = 2,
        points: [CGPoint] = [],
        text: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.lineWidth = lineWidth
        self.points = points
        self.text = text
    }
}

/// 矢量标注文档。坐标相对 baseImage 像素空间。
/// REQ: A-01–A-03
public struct AnnotationDocument: Codable, Sendable {
    public var shapes: [Shape]

    public init(shapes: [Shape] = []) {
        self.shapes = shapes
    }
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

    public func add(_ shape: Shape) {
        undoStack.append(document)
        redoStack.removeAll()
        document.shapes.append(shape)
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

    public func exportFlattened(base: CGImage) -> CGImage? {
        // M2: 绘制 shapes；mosaic/blur 走 Core Image
        base
    }
}

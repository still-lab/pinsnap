import Foundation

public enum CaptureAnnotateTool: Int, CaseIterable, Sendable {
    case shape
    case arrow
    case pen
    case mosaic
    case text

    public var tip: String {
        switch self {
        case .shape: return "形状"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        }
    }
}

public enum CaptureShapeStyle: Int, Sendable {
    case rect
    case ellipse
}

public enum CaptureArrowStyle: Int, Sendable {
    case line
    case arrow
}

public enum CaptureMosaicStyle: Int, Sendable {
    case mosaic
    case blur
}

public enum CapturePenStyle: Int, Sendable {
    case pen
    case marker
    case eraser
}

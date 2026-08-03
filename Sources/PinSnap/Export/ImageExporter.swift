import CoreGraphics
import Foundation

public enum ImageFormat: String, Sendable {
    case png
    case jpeg
}

public protocol ImageExporterProtocol: Sendable {
    func copyToClipboard(_ image: CGImage) throws
    func save(_ image: CGImage, to url: URL, format: ImageFormat) throws
}

public struct ImageExporter: ImageExporterProtocol {
    public init() {}

    public func copyToClipboard(_ image: CGImage) throws {
        // M1: NSPasteboard
    }

    public func save(_ image: CGImage, to url: URL, format: ImageFormat) throws {
        // M1: ImageIO
    }
}

/// Pro：文件名模板。REQ: E-03
public struct FilenameTemplate: Sendable {
    public var pattern: String

    public static let `default` = FilenameTemplate(
        pattern: "PinSnap-{yyyy}{MM}{dd}-{HHmmss}"
    )

    public init(pattern: String) {
        self.pattern = pattern
    }

    public func render(date: Date = Date(), width: Int, height: Int) -> String {
        // M3 / v1.2
        pattern
    }
}

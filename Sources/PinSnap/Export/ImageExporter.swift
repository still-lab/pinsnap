import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, Sendable {
    case png
    case jpeg
}

public protocol ImageExporterProtocol: Sendable {
    func copyToClipboard(_ image: CGImage) throws
    func save(_ image: CGImage, to url: URL, format: ImageFormat) throws
    func crop(_ image: CGImage, pixelRect: CGRect) -> CGImage?
    func crop(frame: ScreenFrame, selection: CaptureSelection, geometry: ScreenGeometryProtocol) -> CGImage?
}

public struct ImageExporter: ImageExporterProtocol {
    public init() {}

    public func copyToClipboard(_ image: CGImage) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.failed("无法编码 PNG")
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
    }

    public func save(_ image: CGImage, to url: URL, format: ImageFormat) throws {
        let type: UTType = format == .png ? .png : .jpeg
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CaptureError.failed("无法写入文件")
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.failed("写入失败")
        }
    }

    public func crop(_ image: CGImage, pixelRect: CGRect) -> CGImage? {
        let scaled = CGRect(
            x: pixelRect.origin.x,
            y: CGFloat(image.height) - pixelRect.origin.y - pixelRect.height,
            width: pixelRect.width,
            height: pixelRect.height
        ).integral
        return image.cropping(to: scaled)
    }

    public func crop(frame: ScreenFrame, selection: CaptureSelection, geometry: ScreenGeometryProtocol) -> CGImage? {
        let pr = geometry.pixelRect(for: selection)
        return crop(frame.image, pixelRect: pr)
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

    public func render(date: Date = Date(), width: Int = 0, height: Int = 0) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        var name = pattern
        let map: [(String, String)] = [
            ("{yyyy}", fmt(date, "yyyy")),
            ("{MM}", fmt(date, "MM")),
            ("{dd}", fmt(date, "dd")),
            ("{HHmmss}", fmt(date, "HHmmss")),
            ("{width}", "\(width)"),
            ("{height}", "\(height)"),
        ]
        for (k, v) in map { name = name.replacingOccurrences(of: k, with: v) }
        return name
    }

    private func fmt(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }
}

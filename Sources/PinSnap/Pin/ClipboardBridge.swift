import AppKit
import CoreGraphics
import Foundation

public enum ClipboardContent: Sendable {
    case image(CGImage)
    case textRendered(CGImage)
    case colorCard(CGImage, hex: String)
}

public enum ClipboardBridgeError: Error, LocalizedError, Sendable {
    case empty
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .empty: return "剪贴板为空"
        case .unsupported: return "当前剪贴板内容无法贴图"
        }
    }
}

/// 剪贴板 → 可贴图像。优先级：图像 → 图片文件 → 颜色 → 文本。
public protocol ClipboardBridgeProtocol: Sendable {
    func resolve() throws -> ClipboardContent
}

public struct ClipboardBridge: ClipboardBridgeProtocol {
    public init() {}

    public func resolve() throws -> ClipboardContent {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let img = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return .image(img)
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first,
           let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return .image(img)
        }
        if let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            if let hex = parseHex(str) {
                return .colorCard(renderColorCard(hex), hex: hex)
            }
            return .textRendered(renderText(str))
        }
        if pb.pasteboardItems == nil || pb.pasteboardItems?.isEmpty == true {
            throw ClipboardBridgeError.empty
        }
        throw ClipboardBridgeError.unsupported
    }

    private func parseHex(_ s: String) -> String? {
        var t = s
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6 || t.count == 3, t.allSatisfy(\.isHexDigit) else { return nil }
        if t.count == 3 {
            t = t.map { "\($0)\($0)" }.joined()
        }
        return "#" + t.uppercased()
    }

    private func renderColorCard(_ hex: String) -> CGImage {
        let size = CGSize(width: 160, height: 100)
        let img = NSImage(size: size)
        img.lockFocus()
        (NSColor(hex: hex) ?? .red).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
        ]
        (hex as NSString).draw(at: NSPoint(x: 12, y: 12), withAttributes: attrs)
        img.unlockFocus()
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    private func renderText(_ text: String) -> CGImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
        ]
        let ns = NSAttributedString(string: text, attributes: attrs)
        let size = ns.boundingRect(with: NSSize(width: 420, height: 2000), options: [.usesLineFragmentOrigin]).integral.size
        let pad = NSSize(width: size.width + 24, height: size.height + 24)
        let img = NSImage(size: pad)
        img.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: pad)).fill()
        ns.draw(in: NSRect(x: 12, y: 12, width: size.width, height: size.height))
        img.unlockFocus()
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        var t = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: 1
        )
    }
}

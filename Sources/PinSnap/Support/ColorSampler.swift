import AppKit
import CoreGraphics
import Foundation

/// 取色值格式。REQ: C-09 / F-064
public enum ColorValueFormat: String, CaseIterable, Sendable {
    case hex
    case rgb

    public static let defaultsKey = "pinsnap.colorFormat"

    public static var current: ColorValueFormat {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? hex.rawValue
        return ColorValueFormat(rawValue: raw) ?? .hex
    }

    public func string(for color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", r, g, b)
        case .rgb:
            return "rgb(\(r), \(g), \(b))"
        }
    }
}

public enum ColorSampler {
    /// 从截帧采样逻辑点颜色（全局 AppKit 坐标）。
    public static func sample(at global: CGPoint, in frames: [ScreenFrame]) -> NSColor? {
        guard let frame = frames.first(where: { $0.logicalBounds.contains(global) }) else { return nil }
        let lx = global.x - frame.logicalBounds.minX
        let ly = global.y - frame.logicalBounds.minY
        let px = Int((lx * frame.scale).rounded(.down))
        let pyTopLeft = frame.image.height - Int((ly * frame.scale).rounded(.down)) - 1
        return pixelColor(frame.image, x: px, y: pyTopLeft)
    }

    public static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func pixelColor(_ image: CGImage, x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        let a = CGFloat(pixel[3]) / 255
        guard a > 0 else {
            return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        }
        return NSColor(
            srgbRed: CGFloat(pixel[0]) / 255 / a,
            green: CGFloat(pixel[1]) / 255 / a,
            blue: CGFloat(pixel[2]) / 255 / a,
            alpha: 1
        )
    }
}

/// 光标旁色值条。REQ: C-09
@MainActor
final class ColorSampleHUD: NSPanel {
    private let swatch = NSView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 128, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver + 2
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let chrome = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 128, height: 28))
        chrome.material = .popover
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 6
        chrome.layer?.masksToBounds = true

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [swatch, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(stack)
        contentView = chrome

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            stack.topAnchor.constraint(equalTo: chrome.topAnchor),
            stack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 16),
            swatch.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    func show(color: NSColor, text: String, near global: CGPoint) {
        swatch.layer?.backgroundColor = color.cgColor
        label.stringValue = text
        label.sizeToFit()
        let w = max(96, label.fittingSize.width + 36)
        let h: CGFloat = 28
        var x = global.x + 16
        var y = global.y - h - 12
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(global) }) ?? NSScreen.main {
            x = min(max(x, screen.frame.minX + 4), screen.frame.maxX - w - 4)
            y = min(max(y, screen.frame.minY + 4), screen.frame.maxY - h - 4)
        }
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

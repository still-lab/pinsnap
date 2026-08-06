import AppKit
import CoreGraphics
import Foundation

/// 取色值格式。REQ: C-09 / F-064
public enum ColorValueFormat: String, CaseIterable, Sendable {
    case hex
    case rgb

    public static let defaultsKey = "pinsnap.colorFormat"

    public static var current: ColorValueFormat {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? hex.rawValue
            return ColorValueFormat(rawValue: raw) ?? .hex
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    public mutating func toggle() {
        self = self == .hex ? .rgb : .hex
        ColorValueFormat.current = self
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

    /// 裁一块放大镜用的像素区域（中心为 global）。
    public static func magnifierPatch(
        at global: CGPoint,
        in frames: [ScreenFrame],
        radiusLogical: CGFloat = 8
    ) -> (image: CGImage, color: NSColor?)? {
        guard let frame = frames.first(where: { $0.logicalBounds.contains(global) }) else { return nil }
        let scale = frame.scale
        let lx = (global.x - frame.logicalBounds.minX) * scale
        let ly = (global.y - frame.logicalBounds.minY) * scale
        let r = radiusLogical * scale
        let pixelRect = CGRect(x: lx - r, y: ly - r, width: r * 2, height: r * 2)
        guard let cropped = ImageExporter().crop(frame.image, pixelRect: pixelRect) else { return nil }
        let color = sample(at: global, in: frames)
        return (cropped, color)
    }

    public static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func pixelColor(_ image: CGImage, x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        // 优先直读位图，避免 CGContext 绘制时的坐标系/色域转换误差
        if let direct = readRGBAPixel(image, x: x, y: y) {
            return direct
        }
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
        // y 为图像顶左原点；CGContext 绘制原点在左下，需换算
        ctx.interpolationQuality = .none
        ctx.draw(
            image,
            in: CGRect(
                x: -CGFloat(x),
                y: CGFloat(y) - CGFloat(image.height - 1),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        return colorFromPremultipliedRGBA(pixel)
    }

    /// 从 CGImage 数据提供方按顶左原点读取一像素（兼容常见 8bpc RGBA/BGRA）。
    private static func readRGBAPixel(_ image: CGImage, x: Int, y: Int) -> NSColor? {
        guard let provider = image.dataProvider, let data = provider.data else { return nil }
        let ptr = CFDataGetBytePtr(data)
        let length = CFDataGetLength(data)
        let bpp = max(image.bitsPerPixel / 8, 1)
        let bpc = image.bitsPerComponent
        guard bpc == 8, bpp >= 3 else { return nil }
        let row = max(image.bytesPerRow, image.width * bpp)
        let offset = y * row + x * bpp
        guard offset + bpp <= length else { return nil }

        let byteOrder = CGBitmapInfo(rawValue: image.bitmapInfo.rawValue).intersection(.byteOrderMask)
        let alphaInfo = image.alphaInfo
        let bytes = (0..<bpp).map { ptr![offset + $0] }

        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
        switch (byteOrder, alphaInfo) {
        case (.byteOrder32Little, .premultipliedFirst), (.byteOrder32Little, .first), (.byteOrder32Little, .noneSkipFirst):
            // BGRA
            b = bytes[0]; g = bytes[1]; r = bytes[2]
            a = bpp >= 4 ? bytes[3] : 255
        case (.byteOrder32Little, .premultipliedLast), (.byteOrder32Little, .last), (.byteOrder32Little, .noneSkipLast):
            // ABGR unusual — fall through to draw path
            return nil
        case (_, .premultipliedLast), (_, .last), (_, .noneSkipLast):
            // RGBA
            r = bytes[0]; g = bytes[1]; b = bytes[2]
            a = bpp >= 4 ? bytes[3] : 255
        case (_, .premultipliedFirst), (_, .first), (_, .noneSkipFirst):
            // ARGB
            a = bytes[0]; r = bytes[1]; g = bytes[2]; b = bytes[3]
        default:
            if bpp == 3 || bpp == 4 {
                r = bytes[0]; g = bytes[1]; b = bytes[2]
                a = bpp >= 4 ? bytes[3] : 255
            } else {
                return nil
            }
        }
        return colorFromPremultipliedRGBA([r, g, b, a])
    }

    private static func colorFromPremultipliedRGBA(_ pixel: [UInt8]) -> NSColor {
        let a = CGFloat(pixel[3]) / 255
        if a > 0.001 && a < 0.999 {
            return NSColor(
                srgbRed: min(CGFloat(pixel[0]) / 255 / a, 1),
                green: min(CGFloat(pixel[1]) / 255 / a, 1),
                blue: min(CGFloat(pixel[2]) / 255 / a, 1),
                alpha: 1
            )
        }
        return NSColor(
            srgbRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }
}

/// 光标旁色卡：双格式 + 快捷键说明。REQ: C-09
@MainActor
final class ColorSampleHUD: NSPanel {
    private let swatch = NSView()
    private let hexLabel = NSTextField(labelWithString: "")
    private let rgbLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var activeFormat: ColorValueFormat = .current
    private var lastColor: NSColor?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 168, height: 72),
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

        let chrome = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 168, height: 72))
        chrome.material = .popover
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 8
        chrome.layer?.masksToBounds = true

        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 4
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false

        configureValueLabel(hexLabel)
        configureValueLabel(rgbLabel)
        hintLabel.font = .systemFont(ofSize: 10, weight: .regular)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let textCol = NSStackView(views: [hexLabel, rgbLabel, hintLabel])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 2
        textCol.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [swatch, textCol])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(row)
        contentView = chrome

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            row.topAnchor.constraint(equalTo: chrome.topAnchor),
            row.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 28),
            swatch.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func configureValueLabel(_ label: NSTextField) {
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    func show(color: NSColor, near global: CGPoint) {
        if lastColor == nil {
            activeFormat = .current
        }
        lastColor = color
        swatch.layer?.backgroundColor = color.cgColor
        let prefs = HotKeyPreferences.shared
        hintLabel.stringValue = "\(prefs.displayString(for: .overlayColorCopy)) 复制 · \(prefs.displayString(for: .overlayColorToggle)) 切换"
        refreshLabels()
        let w: CGFloat = 168
        let h: CGFloat = 72
        var x = global.x + 18
        var y = global.y - h - 14
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(global) }) ?? NSScreen.main {
            x = min(max(x, screen.frame.minX + 4), screen.frame.maxX - w - 4)
            y = min(max(y, screen.frame.minY + 4), screen.frame.maxY - h - 4)
        }
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        orderFrontRegardless()
    }

    func toggleFormat() {
        activeFormat.toggle()
        refreshLabels()
    }

    func copyActive() -> String? {
        guard let color = lastColor else { return nil }
        let text = activeFormat.string(for: color)
        ColorSampler.copyToPasteboard(text)
        return text
    }

    func hide() {
        lastColor = nil
        orderOut(nil)
    }

    private func refreshLabels() {
        guard let color = lastColor else { return }
        let hex = ColorValueFormat.hex.string(for: color)
        let rgb = ColorValueFormat.rgb.string(for: color)
        hexLabel.stringValue = activeFormat == .hex ? "▸ \(hex)" : "  \(hex)"
        rgbLabel.stringValue = activeFormat == .rgb ? "▸ \(rgb)" : "  \(rgb)"
        hexLabel.textColor = activeFormat == .hex ? .labelColor : .secondaryLabelColor
        rgbLabel.textColor = activeFormat == .rgb ? .labelColor : .secondaryLabelColor
    }
}

/// 光标旁像素放大镜。REQ: C-08
@MainActor
final class MagnifierHUD: NSPanel {
    private let imageView = NSImageView()
    private let crosshair = CAShapeLayer()
    private let size: CGFloat = 110

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
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

        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = size / 2
        chrome.layer?.masksToBounds = true
        chrome.layer?.borderWidth = 2
        chrome.layer?.borderColor = NSColor.white.cgColor
        chrome.layer?.backgroundColor = NSColor.black.cgColor

        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = chrome.bounds
        imageView.autoresizingMask = [.width, .height]
        chrome.addSubview(imageView)

        crosshair.strokeColor = NSColor.systemRed.cgColor
        crosshair.fillColor = nil
        crosshair.lineWidth = 1
        let mid = size / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: mid - 10, y: mid))
        path.addLine(to: CGPoint(x: mid + 10, y: mid))
        path.move(to: CGPoint(x: mid, y: mid - 10))
        path.addLine(to: CGPoint(x: mid, y: mid + 10))
        crosshair.path = path
        chrome.layer?.addSublayer(crosshair)

        contentView = chrome
    }

    func show(patch: CGImage, near global: CGPoint) {
        imageView.image = NSImage(cgImage: patch, size: NSSize(width: size, height: size))
        let w = size
        let h = size
        var x = global.x + 20
        var y = global.y + 20
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(global) }) ?? NSScreen.main {
            if x + w > screen.frame.maxX - 4 { x = global.x - w - 20 }
            if y + h > screen.frame.maxY - 4 { y = global.y - h - 20 }
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

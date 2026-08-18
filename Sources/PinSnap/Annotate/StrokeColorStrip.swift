import AppKit

/// 子工具条描边色：左侧预览色块 + 可拖游标的色相条。
/// Overlay 与 Pin 共用；色相 0…1 对应满饱和彩虹。
@MainActor
public final class StrokeColorStrip: NSView {
    public static let defaultHue: CGFloat = 0
    public static let preferredSize = NSSize(width: 168, height: 22)

    public var onHueChange: ((CGFloat) -> Void)?

    private var hueValue: CGFloat = defaultHue
    private var isTracking = false

    private let previewSize: CGFloat = 16
    private let previewGap: CGFloat = 6
    private let trackHeight: CGFloat = 8
    private let thumbSize: CGFloat = 12

    public var hue: CGFloat { hueValue }

    public var strokeColor: NSColor { Self.color(hue: hueValue) }

    public override var intrinsicContentSize: NSSize { Self.preferredSize }
    public override var isOpaque: Bool { false }
    public override var isFlipped: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        toolTip = "颜色"
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.preferredSize.width),
            heightAnchor.constraint(equalToConstant: Self.preferredSize.height),
        ])
    }

    public func setHue(_ hue: CGFloat, notify: Bool) {
        let next = Self.clamp(hue)
        if next != hueValue {
            hueValue = next
            needsDisplay = true
        }
        if notify {
            onHueChange?(next)
        }
    }

    nonisolated public static func clamp(_ hue: CGFloat) -> CGFloat {
        min(1, max(0, hue))
    }

    nonisolated public static func color(hue: CGFloat) -> NSColor {
        let rgb = hsbToRGB(h: clamp(hue), s: 1, v: 1)
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    /// 标准 HSB → RGB，保证色相 0 为纯红并与 `Shape` 的 sRGB 分量一致。
    nonisolated static func hsbToRGB(h: CGFloat, s: CGFloat, v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        if s <= 0 { return (v, v, v) }
        let hh = (h * 6).truncatingRemainder(dividingBy: 6)
        let sector = Int(hh)
        let f = hh - CGFloat(sector)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch sector {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func resetCursorRects() {
        addCursorRect(trackHitRect, cursor: .pointingHand)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard trackHitRect.contains(point) else { return }
        isTracking = true
        setHue(hue(at: point), notify: true)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        setHue(hue(at: convert(event.locationInWindow, from: nil)), notify: true)
    }

    public override func mouseUp(with event: NSEvent) {
        if isTracking {
            setHue(hue(at: convert(event.locationInWindow, from: nil)), notify: true)
        }
        isTracking = false
    }

    public override func draw(_ dirtyRect: NSRect) {
        let color = strokeColor
        drawPreview(color)
        drawTrack()
        drawThumb(color)
    }

    private var previewRect: NSRect {
        let y = (bounds.height - previewSize) / 2
        return NSRect(x: 0, y: y, width: previewSize, height: previewSize)
    }

    private var trackRect: NSRect {
        let x = previewSize + previewGap
        let y = (bounds.height - trackHeight) / 2
        return NSRect(x: x, y: y, width: bounds.width - x, height: trackHeight)
    }

    private var trackHitRect: NSRect {
        NSRect(x: previewSize + previewGap, y: 0, width: bounds.width - previewSize - previewGap, height: bounds.height)
    }

    private func hue(at point: NSPoint) -> CGFloat {
        let track = trackRect
        let inset = thumbSize / 2
        let minX = track.minX + inset
        let maxX = track.maxX - inset
        let span = max(1, maxX - minX)
        return Self.clamp((point.x - minX) / span)
    }

    private func thumbCenter() -> NSPoint {
        let track = trackRect
        let inset = thumbSize / 2
        let minX = track.minX + inset
        let maxX = track.maxX - inset
        return NSPoint(x: minX + hueValue * (maxX - minX), y: bounds.midY)
    }

    private func drawPreview(_ color: NSColor) {
        let rect = previewRect
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        color.setFill()
        path.fill()
        NSColor(calibratedWhite: 0.15, alpha: 0.45).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawTrack() {
        let rect = trackRect
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let gradient = hueGradient() {
            gradient.draw(in: rect, angle: 0)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 0.15, alpha: 0.35).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawThumb(_ color: NSColor) {
        let c = thumbCenter()
        let outer = NSRect(
            x: c.x - thumbSize / 2,
            y: c.y - thumbSize / 2,
            width: thumbSize,
            height: thumbSize
        )
        let outerPath = NSBezierPath(ovalIn: outer)
        NSColor.white.setFill()
        outerPath.fill()
        NSColor(calibratedWhite: 0.1, alpha: 0.45).setStroke()
        outerPath.lineWidth = 0.5
        outerPath.stroke()

        let inner = outer.insetBy(dx: 2.5, dy: 2.5)
        let innerPath = NSBezierPath(ovalIn: inner)
        color.setFill()
        innerPath.fill()
    }

    private func hueGradient() -> NSGradient? {
        let colors = (0...6).map { i -> NSColor in
            Self.color(hue: CGFloat(i) / 6)
        }
        return NSGradient(colors: colors)
    }
}

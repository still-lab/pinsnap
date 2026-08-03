import AppKit
import Foundation

/// OCR 叠层：浅底标出识别区；自定义拖选支持跨行；复制写纯文本。
@MainActor
final class OCRTextOverlayView: NSView {
    private struct LineBox {
        var text: String
        var frame: CGRect
        var font: NSFont
        var band: NSView
    }

    /// 阅读顺序（自上而下）下的选区端点。
    private struct Caret: Comparable {
        var line: Int
        var offset: Int

        static func < (lhs: Caret, rhs: Caret) -> Bool {
            if lhs.line != rhs.line { return lhs.line < rhs.line }
            return lhs.offset < rhs.offset
        }
    }

    private var lines: [LineBox] = []
    private var anchor: Caret?
    private var focus: Caret?
    private var selectionLayer = CAShapeLayer()

    /// 识别区底色（低透明，不抢底图文字）
    private let bandColor = NSColor.systemTeal.withAlphaComponent(0.16)
    /// 拖选高亮（低透明，不遮字）
    private let selectionFill = NSColor.systemBlue.withAlphaComponent(0.20)

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        selectionLayer.fillColor = selectionFill.cgColor
        selectionLayer.strokeColor = nil
        layer?.addSublayer(selectionLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(lines raw: [OCRLine], imagePixelSize: CGSize, scale: CGFloat) {
        teardown()
        guard imagePixelSize.width > 0, imagePixelSize.height > 0, scale > 0 else { return }

        var built: [LineBox] = []
        for line in raw {
            let logical = OCRGeometry.logicalRect(
                normalized: line.normalizedRect,
                imagePixelSize: imagePixelSize,
                scale: scale
            )
            guard logical.width >= 2, logical.height >= 2, !line.text.isEmpty else { continue }
            let fontSize = max(9, min(logical.height * 0.85, 72))
            let font = NSFont.systemFont(ofSize: fontSize)
            let frame = logical.insetBy(dx: -1, dy: -1)

            let band = NSView(frame: frame)
            band.wantsLayer = true
            band.layer?.backgroundColor = bandColor.cgColor
            band.layer?.cornerRadius = 2
            // 命中交给父视图做跨行拖选
            band.layer?.masksToBounds = true
            addSubview(band)

            built.append(LineBox(text: line.text, frame: frame, font: font, band: band))
        }

        // 阅读顺序：屏幕上方的行在前（AppKit y 越大越靠上）
        built.sort { $0.frame.midY > $1.frame.midY }
        lines = built
        clearSelection()
    }

    func teardown() {
        lines.forEach { $0.band.removeFromSuperview() }
        lines.removeAll()
        clearSelection()
    }

    @discardableResult
    func copySelectionToPasteboard() -> Bool {
        let text = selectedPlainText()
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
        return true
    }

    func selectedPlainText() -> String {
        guard let range = orderedSelection() else { return "" }
        var parts: [String] = []
        for lineIdx in range.start.line...range.end.line {
            let ns = lines[lineIdx].text as NSString
            let start = (lineIdx == range.start.line) ? range.start.offset : 0
            let end = (lineIdx == range.end.line) ? range.end.offset : ns.length
            let a = max(0, min(start, ns.length))
            let b = max(a, min(end, ns.length))
            if b > a {
                parts.append(ns.substring(with: NSRange(location: a, length: b - a)))
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Mouse (跨行拖选)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let caret = caret(at: p) else {
            clearSelection()
            return
        }
        anchor = caret
        focus = caret
        refreshSelectionPath()
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        focus = caret(at: p) ?? focus
        refreshSelectionPath()
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let c = caret(at: p) { focus = c }
        refreshSelectionPath()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point 是父视图坐标系，必须用 frame（或 convert 后再比 bounds）
        guard frame.contains(point) else { return nil }
        return self
    }

    // MARK: - Geometry

    private func caret(at point: CGPoint) -> Caret? {
        guard !lines.isEmpty else { return nil }
        // 最近行（垂直）
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, line) in lines.enumerated() {
            let dy: CGFloat
            if point.y < line.frame.minY { dy = line.frame.minY - point.y }
            else if point.y > line.frame.maxY { dy = point.y - line.frame.maxY }
            else { dy = 0 }
            if dy < bestDist {
                bestDist = dy
                best = i
            }
        }
        let offset = utf16Offset(in: lines[best], atX: point.x)
        return Caret(line: best, offset: offset)
    }

    private func utf16Offset(in line: LineBox, atX x: CGFloat) -> Int {
        let length = (line.text as NSString).length
        guard length > 0 else { return 0 }
        let width = max(line.frame.width, 1)
        let t = (x - line.frame.minX) / width
        let clamped = max(0, min(1, t))
        return Int((clamped * CGFloat(length)).rounded())
    }

    private func xPosition(for offset: Int, in line: LineBox) -> CGFloat {
        let length = max((line.text as NSString).length, 1)
        let o = max(0, min(offset, length))
        return line.frame.minX + (CGFloat(o) / CGFloat(length)) * line.frame.width
    }

    private func orderedSelection() -> (start: Caret, end: Caret)? {
        guard let a = anchor, let b = focus else { return nil }
        return a <= b ? (a, b) : (b, a)
    }

    private func clearSelection() {
        anchor = nil
        focus = nil
        selectionLayer.path = nil
    }

    private func refreshSelectionPath() {
        guard let range = orderedSelection() else {
            selectionLayer.path = nil
            return
        }
        let path = CGMutablePath()
        for lineIdx in range.start.line...range.end.line {
            let line = lines[lineIdx]
            let ns = line.text as NSString
            let start = (lineIdx == range.start.line) ? range.start.offset : 0
            let end = (lineIdx == range.end.line) ? range.end.offset : ns.length
            let a = max(0, min(start, ns.length))
            let b = max(a, min(end, ns.length))
            guard b > a else { continue }
            // 选区落在 Vision 识别框内，按字符比例映射，避免系统字宽估算出框
            let x0 = xPosition(for: a, in: line)
            let x1 = xPosition(for: b, in: line)
            let rect = CGRect(
                x: x0,
                y: line.frame.minY,
                width: max(2, x1 - x0),
                height: line.frame.height
            )
            path.addRect(rect)
        }
        selectionLayer.path = path
    }

    override func layout() {
        super.layout()
        selectionLayer.frame = bounds
    }
}

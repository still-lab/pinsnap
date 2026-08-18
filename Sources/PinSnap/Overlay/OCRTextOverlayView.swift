import AppKit
import Foundation

/// OCR 叠层：浅底标出识别区；点选整行 / 双击选词 / 拖选跨行 / ⌘A 全选；复制仅纯文本。
@MainActor
final class OCRTextOverlayView: NSView {
    private struct LineBox {
        var text: String
        var frame: CGRect
        var font: NSFont
        var band: NSView
        var label: NSTextField?
    }

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
    private var mouseDownPoint: CGPoint?
    private var didDrag = false
    private var copyAllIfEmpty = false

    private let bandColor = NSColor.systemTeal.withAlphaComponent(0.16)
    private let selectionFill = NSColor.systemBlue.withAlphaComponent(0.20)
    private let clickSlop: CGFloat = 4

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

    func apply(lines raw: [OCRLine], imagePixelSize: CGSize, scale: CGFloat, showsText: Bool = false) {
        teardown()
        copyAllIfEmpty = showsText
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
            band.layer?.cornerRadius = 2
            band.layer?.masksToBounds = true
            if showsText {
                band.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
            } else {
                band.layer?.backgroundColor = bandColor.cgColor
            }
            addSubview(band)

            var label: NSTextField?
            if showsText {
                let field = NSTextField(labelWithString: line.text)
                field.font = font
                field.textColor = .labelColor
                field.lineBreakMode = .byTruncatingTail
                field.maximumNumberOfLines = 3
                field.refusesFirstResponder = true
                field.isSelectable = false
                field.isEditable = false
                field.translatesAutoresizingMaskIntoConstraints = true
                field.frame = band.bounds.insetBy(dx: 2, dy: 0)
                field.autoresizingMask = [.width, .height]
                (field.cell as? NSTextFieldCell)?.wraps = true
                field.cell?.truncatesLastVisibleLine = true
                band.addSubview(field)
                label = field
            }

            built.append(LineBox(text: line.text, frame: frame, font: font, band: band, label: label))
        }

        built.sort { $0.frame.midY > $1.frame.midY }
        lines = built
        clearSelection()
    }

    func teardown() {
        lines.forEach {
            $0.label?.removeFromSuperview()
            $0.band.removeFromSuperview()
        }
        lines.removeAll()
        copyAllIfEmpty = false
        clearSelection()
    }

    func selectAll() {
        guard !lines.isEmpty else { return }
        let last = lines.count - 1
        anchor = Caret(line: 0, offset: 0)
        focus = Caret(line: last, offset: (lines[last].text as NSString).length)
        refreshSelectionPath()
    }

    @discardableResult
    func copySelectionToPasteboard() -> Bool {
        writeToPasteboard(selectedPlainText())
    }

    @discardableResult
    func copyAllToPasteboard() -> Bool {
        writeToPasteboard(allPlainText())
    }

    func allPlainText() -> String {
        lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        if !copySelectionToPasteboard(), copyAllIfEmpty {
            _ = copyAllToPasteboard()
        }
    }

    private func writeToPasteboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
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

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        didDrag = false

        if event.clickCount >= 2 {
            selectWord(at: p)
            return
        }

        guard let caret = caret(at: p) else {
            clearSelection()
            return
        }
        anchor = caret
        focus = caret
        refreshSelectionPath()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let start = mouseDownPoint,
           hypot(p.x - start.x, p.y - start.y) > clickSlop {
            didDrag = true
        }
        guard didDrag, anchor != nil else { return }
        focus = caret(at: p) ?? focus
        refreshSelectionPath()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            didDrag = false
        }
        // 单击未拖：选中整行
        if event.clickCount == 1, !didDrag {
            let p = convert(event.locationInWindow, from: nil)
            if let idx = lineIndex(containing: p) ?? nearestLineIndex(to: p) {
                selectLine(idx)
            }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if let c = caret(at: p) { focus = c }
        refreshSelectionPath()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                selectAll()
                return
            case "c":
                if !copySelectionToPasteboard(), copyAllIfEmpty {
                    _ = copyAllToPasteboard()
                }
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        return self
    }

    // MARK: - Selection helpers

    private func selectLine(_ index: Int) {
        guard lines.indices.contains(index) else { return }
        let len = (lines[index].text as NSString).length
        anchor = Caret(line: index, offset: 0)
        focus = Caret(line: index, offset: len)
        refreshSelectionPath()
    }

    private func selectWord(at point: CGPoint) {
        guard let caret = caret(at: point), lines.indices.contains(caret.line) else {
            clearSelection()
            return
        }
        let text = lines[caret.line].text
        let range = wordUTF16Range(in: text, around: caret.offset)
        anchor = Caret(line: caret.line, offset: range.location)
        focus = Caret(line: caret.line, offset: range.location + range.length)
        refreshSelectionPath()
    }

    private func wordUTF16Range(in text: String, around utf16Offset: Int) -> NSRange {
        let ns = text as NSString
        let len = ns.length
        guard len > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = max(0, min(utf16Offset, len))

        var found = NSRange(location: NSNotFound, length: 0)
        ns.enumerateSubstrings(in: NSRange(location: 0, length: len), options: .byWords) { _, range, _, stop in
            if NSLocationInRange(clamped, range)
                || (clamped == range.location + range.length && range.length > 0) {
                found = range
                stop.pointee = true
            } else if clamped < range.location {
                stop.pointee = true
            }
        }
        if found.location != NSNotFound { return found }

        // 无「词」边界时（常见于中文）：选中光标处一个字符
        if clamped >= len {
            return NSRange(location: max(0, len - 1), length: len > 0 ? 1 : 0)
        }
        return NSRange(location: clamped, length: 1)
    }

    private func lineIndex(containing point: CGPoint) -> Int? {
        lines.firstIndex { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func nearestLineIndex(to point: CGPoint) -> Int? {
        guard !lines.isEmpty else { return nil }
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
        return best
    }

    private func caret(at point: CGPoint) -> Caret? {
        guard let best = lineIndex(containing: point) ?? nearestLineIndex(to: point) else { return nil }
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
            let x0 = xPosition(for: a, in: line)
            let x1 = xPosition(for: b, in: line)
            path.addRect(CGRect(
                x: x0,
                y: line.frame.minY,
                width: max(2, x1 - x0),
                height: line.frame.height
            ))
        }
        selectionLayer.path = path
    }

    override func layout() {
        super.layout()
        selectionLayer.frame = bounds
    }
}

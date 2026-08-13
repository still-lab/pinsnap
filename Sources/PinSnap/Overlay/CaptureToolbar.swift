import AppKit
import Foundation

@MainActor
protocol CaptureToolbarDelegate: AnyObject {
    func toolbarSelectTool(_ tool: CaptureAnnotateTool?)
    func toolbarSelectShapeStyle(_ style: CaptureShapeStyle)
    func toolbarSelectArrowStyle(_ style: CaptureArrowStyle)
    func toolbarSelectMosaicStyle(_ style: CaptureMosaicStyle)
    func toolbarSelectPenStyle(_ style: CapturePenStyle)
    func toolbarToggleEyedropper()
    func toolbarUndo()
    func toolbarRedo()
    func toolbarOCR()
    func toolbarScrollCapture()
    func toolbarCopy()
    func toolbarSave()
    func toolbarPin()
}

/// 两层工具条：点「形状」「箭头」「马赛克」展开第二层子项。宽度固定，避免子栏撑开。
@MainActor
final class CaptureToolbar: NSPanel {
    weak var actionHandler: CaptureToolbarDelegate?

    private let buttonSize: CGFloat = 26
    private let rowHeight: CGFloat = 34
    private let sidePad: CGFloat = 6
    private let gap: CGFloat = 4
    private let barWidth: CGFloat = 418
    private let subRowExtra: CGFloat = 28
    private let dividerHeight: CGFloat = 1
    /// 工具条与选区之间的间距
    private let selectionGap: CGFloat = 8

    private var selectedTool: CaptureAnnotateTool?
    private var shapeStyle: CaptureShapeStyle = .rect
    private var arrowStyle: CaptureArrowStyle = .arrow
    private var mosaicStyle: CaptureMosaicStyle = .mosaic
    private var penStyle: CapturePenStyle = .pen
    private var eyedropperOn = false

    private let rootStack = NSStackView()
    private let row1 = NSStackView()
    private let row2 = NSStackView()
    private var toolButtons: [CaptureAnnotateTool: NSButton] = [:]

    private let shapeSubStack = NSStackView()
    private let arrowSubStack = NSStackView()
    private let penSubStack = NSStackView()
    private let mosaicSubStack = NSStackView()
    private var rectButton: NSButton!
    private var ellipseButton: NSButton!
    private var lineModeButton: NSButton!
    private var arrowModeButton: NSButton!
    private var penModeButton: NSButton!
    private var markerModeButton: NSButton!
    private var eraserModeButton: NSButton!
    private var mosaicModeButton: NSButton!
    private var blurModeButton: NSButton!
    private var eyedropperButton: NSButton!
    private var rowDivider: NSView!
    private var pendingFramePreserveTop: Bool?
    private var isApplyingFrame = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: barWidth, height: rowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // contentView 跟窗口 frame 走 autoresizing，避免 width 约束 + setFrame 互相递归 layout
        let chrome = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: barWidth, height: rowHeight))
        chrome.material = .popover
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.appearance = NSAppearance(named: .vibrantLight)
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 8
        chrome.layer?.masksToBounds = true
        chrome.layer?.borderWidth = 0.5
        chrome.layer?.borderColor = NSColor.white.withAlphaComponent(0.65).cgColor
        chrome.autoresizingMask = [.width, .height]

        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.alignment = .leading
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(rootStack)

        row1.orientation = .horizontal
        row1.spacing = gap
        row1.alignment = .centerY
        row1.distribution = .gravityAreas
        row1.edgeInsets = NSEdgeInsets(top: 4, left: sidePad, bottom: 4, right: sidePad)
        row1.translatesAutoresizingMaskIntoConstraints = false
        row1.setHuggingPriority(.defaultHigh, for: .horizontal)

        row2.orientation = .horizontal
        row2.spacing = gap
        row2.alignment = .centerY
        row2.distribution = .gravityAreas
        row2.edgeInsets = NSEdgeInsets(top: 3, left: sidePad, bottom: 3, right: sidePad)
        row2.isHidden = true
        row2.translatesAutoresizingMaskIntoConstraints = false
        row2.setHuggingPriority(.defaultHigh, for: .horizontal)

        // 第一层
        let shapeBtn = iconBtn("rectangle.on.rectangle", tip: "形状", tag: CaptureAnnotateTool.shape.rawValue)
        toolButtons[.shape] = shapeBtn
        row1.addArrangedSubview(shapeBtn)
        for tool in [CaptureAnnotateTool.arrow, .pen, .mosaic] {
            let b = iconBtn(symbol(for: tool), tip: tool.tip, tag: tool.rawValue)
            toolButtons[tool] = b
            row1.addArrangedSubview(b)
        }
        let tBtn = glyphBtn("T", tip: "文字", tag: CaptureAnnotateTool.text.rawValue)
        toolButtons[.text] = tBtn
        row1.addArrangedSubview(tBtn)
        row1.addArrangedSubview(sep())
        row1.addArrangedSubview(actionBtn("arrow.uturn.backward", tip: "撤销", #selector(undoAction)))
        row1.addArrangedSubview(actionBtn("arrow.uturn.forward", tip: "重做", #selector(redoAction)))
        row1.addArrangedSubview(sep())
        eyedropperButton = actionBtn("eyedropper", tip: "取色", #selector(eyedropperAction))
        eyedropperButton.setButtonType(.toggle)
        row1.addArrangedSubview(eyedropperButton)
        row1.addArrangedSubview(actionBtn("doc.text.magnifyingglass", tip: "OCR", #selector(ocrAction)))
        row1.addArrangedSubview(actionBtn("arrow.up.arrow.down", tip: "上下长截", #selector(scrollCaptureAction)))
        row1.addArrangedSubview(actionBtn("pin", tip: "贴图", #selector(pinAction)))
        row1.addArrangedSubview(actionBtn("square.and.arrow.down", tip: "保存", #selector(saveAction)))
        row1.addArrangedSubview(actionBtn("doc.on.doc", tip: "复制", #selector(copyAction)))

        configureSubStack(shapeSubStack)
        rectButton = iconBtn("rectangle", tip: "矩形", tag: 100)
        rectButton.action = #selector(shapeStyleAction(_:))
        ellipseButton = iconBtn("oval", tip: "椭圆", tag: 101)
        ellipseButton.action = #selector(shapeStyleAction(_:))
        shapeSubStack.addArrangedSubview(rectButton)
        shapeSubStack.addArrangedSubview(ellipseButton)

        configureSubStack(arrowSubStack)
        lineModeButton = iconBtn("line.diagonal", tip: "直线", tag: 110)
        lineModeButton.action = #selector(arrowStyleAction(_:))
        arrowModeButton = iconBtn("arrow.up.right", tip: "箭头", tag: 111)
        arrowModeButton.action = #selector(arrowStyleAction(_:))
        arrowSubStack.addArrangedSubview(lineModeButton)
        arrowSubStack.addArrangedSubview(arrowModeButton)

        configureSubStack(penSubStack)
        penModeButton = iconBtn("pencil.tip", tip: "画笔", tag: 120)
        penModeButton.action = #selector(penStyleAction(_:))
        markerModeButton = iconBtn("highlighter", tip: "记号笔", tag: 121)
        markerModeButton.action = #selector(penStyleAction(_:))
        eraserModeButton = iconBtn("eraser.fill", tip: "橡皮", tag: 122)
        eraserModeButton.action = #selector(penStyleAction(_:))
        penSubStack.addArrangedSubview(penModeButton)
        penSubStack.addArrangedSubview(markerModeButton)
        penSubStack.addArrangedSubview(eraserModeButton)

        configureSubStack(mosaicSubStack)
        mosaicModeButton = iconBtn("square.grid.2x2.fill", tip: "马赛克", tag: 200)
        mosaicModeButton.action = #selector(mosaicStyleAction(_:))
        blurModeButton = iconBtn("aqi.medium", tip: "高斯模糊", tag: 201)
        blurModeButton.action = #selector(mosaicStyleAction(_:))
        mosaicSubStack.addArrangedSubview(mosaicModeButton)
        mosaicSubStack.addArrangedSubview(blurModeButton)

        row2.addArrangedSubview(shapeSubStack)
        row2.addArrangedSubview(arrowSubStack)
        row2.addArrangedSubview(penSubStack)
        row2.addArrangedSubview(mosaicSubStack)
        shapeSubStack.isHidden = true
        arrowSubStack.isHidden = true
        penSubStack.isHidden = true
        mosaicSubStack.isHidden = true
        row2.isHidden = true

        rowDivider = NSView()
        rowDivider.wantsLayer = true
        rowDivider.layer?.backgroundColor = NSColor(calibratedWhite: 0.55, alpha: 0.35).cgColor
        rowDivider.translatesAutoresizingMaskIntoConstraints = false
        rowDivider.isHidden = true

        rootStack.addArrangedSubview(row1)
        rootStack.addArrangedSubview(rowDivider)
        rootStack.addArrangedSubview(row2)

        contentView = chrome
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: chrome.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
            rowDivider.heightAnchor.constraint(equalToConstant: dividerHeight),
            rowDivider.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor, constant: sidePad),
            rowDivider.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor, constant: -sidePad),
        ])
        refreshSelectionUI(resizeWindow: false)
    }

    var width: CGFloat { barWidth }
    var height: CGFloat {
        row2.isHidden ? rowHeight : rowHeight + dividerHeight + subRowExtra
    }

    func setSelectedTool(_ tool: CaptureAnnotateTool?) {
        selectedTool = tool
        refreshSelectionUI()
    }

    func setShapeStyle(_ style: CaptureShapeStyle) {
        shapeStyle = style
        refreshSelectionUI()
    }

    func setMosaicStyle(_ style: CaptureMosaicStyle) {
        mosaicStyle = style
        refreshSelectionUI()
    }

    func setArrowStyle(_ style: CaptureArrowStyle) {
        arrowStyle = style
        refreshSelectionUI()
    }

    func setPenStyle(_ style: CapturePenStyle) {
        penStyle = style
        refreshSelectionUI()
    }

    func setEyedropperOn(_ on: Bool) {
        eyedropperOn = on
        refreshSelectionUI()
    }

    func place(under selection: CGRect, inScreenBounds screen: CGRect, bringToFront: Bool = true) {
        let h = height
        let w = barWidth
        var x = selection.midX - w / 2
        var y = selection.minY - h - selectionGap
        if y < screen.minY + 2 {
            y = min(selection.maxY + selectionGap, screen.maxY - h - 2)
        }
        x = min(max(x, screen.minX + 2), screen.maxX - w - 2)
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
        if bringToFront || !isVisible {
            orderFrontRegardless()
        }
    }

    private func configureSubStack(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.spacing = gap
        stack.alignment = .centerY
    }

    private func applyFrame(preserveOrigin: Bool) {
        let h = height
        let w = barWidth
        let next: NSRect
        if preserveOrigin {
            let top = frame.maxY
            next = NSRect(x: frame.origin.x, y: top - h, width: w, height: h)
        } else {
            next = NSRect(x: frame.origin.x, y: frame.origin.y, width: w, height: h)
        }
        guard !next.equalTo(frame) else { return }
        setFrame(next, display: false)
    }

    /// 延后到当前 layout 结束后再改窗口尺寸，避免 layoutSubtreeIfNeeded 递归。
    private func scheduleApplyFrame(preserveTop: Bool) {
        if let pending = pendingFramePreserveTop {
            pendingFramePreserveTop = pending || preserveTop
        } else {
            pendingFramePreserveTop = preserveTop
        }
        // main.async 明确排到本轮 layout 之后；Task 有时仍会落在同一 layout pass
        DispatchQueue.main.async { [weak self] in
            guard let self, let preserve = self.pendingFramePreserveTop else { return }
            self.pendingFramePreserveTop = nil
            guard !self.isApplyingFrame else { return }
            self.isApplyingFrame = true
            self.applyFrame(preserveOrigin: preserve)
            self.isApplyingFrame = false
        }
    }

    private func refreshSelectionUI(resizeWindow: Bool = true) {
        let idle = NSColor(calibratedWhite: 0.2, alpha: 1)
        for (t, b) in toolButtons {
            let on = t == selectedTool
            b.state = on ? .on : .off
            let color: NSColor = on ? .controlAccentColor : idle
            b.contentTintColor = color
            if t == .text {
                b.attributedTitle = NSAttributedString(
                    string: "T",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: color,
                    ]
                )
            }
        }

        let showShape = selectedTool == .shape
        let showArrow = selectedTool == .arrow
        let showPen = selectedTool == .pen
        let showMosaic = selectedTool == .mosaic
        let showSub = showShape || showArrow || showPen || showMosaic

        // 只用 isHidden，不在 layout 中增删 arrangedSubview
        shapeSubStack.isHidden = !showShape
        arrowSubStack.isHidden = !showArrow
        penSubStack.isHidden = !showPen
        mosaicSubStack.isHidden = !showMosaic
        row2.isHidden = !showSub
        rowDivider.isHidden = !showSub

        rectButton.state = shapeStyle == .rect ? .on : .off
        ellipseButton.state = shapeStyle == .ellipse ? .on : .off
        rectButton.contentTintColor = shapeStyle == .rect ? .controlAccentColor : idle
        ellipseButton.contentTintColor = shapeStyle == .ellipse ? .controlAccentColor : idle

        lineModeButton.state = arrowStyle == .line ? .on : .off
        arrowModeButton.state = arrowStyle == .arrow ? .on : .off
        lineModeButton.contentTintColor = arrowStyle == .line ? .controlAccentColor : idle
        arrowModeButton.contentTintColor = arrowStyle == .arrow ? .controlAccentColor : idle

        penModeButton.state = penStyle == .pen ? .on : .off
        markerModeButton.state = penStyle == .marker ? .on : .off
        eraserModeButton.state = penStyle == .eraser ? .on : .off
        penModeButton.contentTintColor = penStyle == .pen ? .controlAccentColor : idle
        markerModeButton.contentTintColor = penStyle == .marker ? .controlAccentColor : idle
        eraserModeButton.contentTintColor = penStyle == .eraser ? .controlAccentColor : idle

        mosaicModeButton.state = mosaicStyle == .mosaic ? .on : .off
        blurModeButton.state = mosaicStyle == .blur ? .on : .off
        mosaicModeButton.contentTintColor = mosaicStyle == .mosaic ? .controlAccentColor : idle
        blurModeButton.contentTintColor = mosaicStyle == .blur ? .controlAccentColor : idle

        eyedropperButton.state = eyedropperOn ? .on : .off
        eyedropperButton.contentTintColor = eyedropperOn ? .controlAccentColor : idle

        if resizeWindow {
            scheduleApplyFrame(preserveTop: true)
        }
    }

    private func symbol(for tool: CaptureAnnotateTool) -> String {
        switch tool {
        case .shape: return "rectangle.on.rectangle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .mosaic: return "square.grid.2x2.fill"
        case .text: return "textformat"
        }
    }

    private func iconBtn(_ symbol: String, tip: String, tag: Int) -> NSButton {
        let b = NSButton(frame: NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize))
        b.bezelStyle = .shadowlessSquare
        b.isBordered = false
        b.setButtonType(.toggle)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.image?.isTemplate = true
        b.toolTip = tip
        b.tag = tag
        b.target = self
        b.action = #selector(toolAction(_:))
        b.imagePosition = .imageOnly
        b.contentTintColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: buttonSize),
            b.heightAnchor.constraint(equalToConstant: buttonSize),
        ])
        return b
    }

    private func glyphBtn(_ glyph: String, tip: String, tag: Int) -> NSButton {
        let idle = NSColor(calibratedWhite: 0.2, alpha: 1)
        let b = iconBtn("circle", tip: tip, tag: tag)
        b.image = nil
        b.attributedTitle = NSAttributedString(
            string: glyph,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: idle,
            ]
        )
        b.imagePosition = .noImage
        return b
    }

    private func actionBtn(_ symbol: String, tip: String, _ sel: Selector) -> NSButton {
        let b = iconBtn(symbol, tip: tip, tag: -1)
        b.setButtonType(.momentaryLight)
        b.action = sel
        return b
    }

    private func sep() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.55, alpha: 0.45).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 14),
        ])
        return v
    }

    @objc private func toolAction(_ sender: NSButton) {
        guard let tool = CaptureAnnotateTool(rawValue: sender.tag) else { return }
        eyedropperOn = false
        if selectedTool == tool {
            selectedTool = nil
            actionHandler?.toolbarSelectTool(nil)
        } else {
            selectedTool = tool
            actionHandler?.toolbarSelectTool(tool)
            if tool == .shape {
                actionHandler?.toolbarSelectShapeStyle(shapeStyle)
            } else if tool == .arrow {
                actionHandler?.toolbarSelectArrowStyle(arrowStyle)
            } else if tool == .pen {
                actionHandler?.toolbarSelectPenStyle(penStyle)
            } else if tool == .mosaic {
                actionHandler?.toolbarSelectMosaicStyle(mosaicStyle)
            }
        }
        refreshSelectionUI()
    }

    @objc private func shapeStyleAction(_ sender: NSButton) {
        shapeStyle = sender.tag == 101 ? .ellipse : .rect
        eyedropperOn = false
        selectedTool = .shape
        actionHandler?.toolbarSelectTool(.shape)
        actionHandler?.toolbarSelectShapeStyle(shapeStyle)
        refreshSelectionUI()
    }

    @objc private func arrowStyleAction(_ sender: NSButton) {
        arrowStyle = sender.tag == 110 ? .line : .arrow
        eyedropperOn = false
        selectedTool = .arrow
        actionHandler?.toolbarSelectTool(.arrow)
        actionHandler?.toolbarSelectArrowStyle(arrowStyle)
        refreshSelectionUI()
    }

    @objc private func mosaicStyleAction(_ sender: NSButton) {
        mosaicStyle = sender.tag == 201 ? .blur : .mosaic
        eyedropperOn = false
        selectedTool = .mosaic
        actionHandler?.toolbarSelectTool(.mosaic)
        actionHandler?.toolbarSelectMosaicStyle(mosaicStyle)
        refreshSelectionUI()
    }

    @objc private func penStyleAction(_ sender: NSButton) {
        switch sender.tag {
        case 121: penStyle = .marker
        case 122: penStyle = .eraser
        default: penStyle = .pen
        }
        eyedropperOn = false
        selectedTool = .pen
        actionHandler?.toolbarSelectTool(.pen)
        actionHandler?.toolbarSelectPenStyle(penStyle)
        refreshSelectionUI()
    }

    @objc private func eyedropperAction() {
        actionHandler?.toolbarToggleEyedropper()
    }

    @objc private func undoAction() { actionHandler?.toolbarUndo() }
    @objc private func redoAction() { actionHandler?.toolbarRedo() }
    @objc private func ocrAction() { actionHandler?.toolbarOCR() }
    @objc private func scrollCaptureAction() { actionHandler?.toolbarScrollCapture() }
    @objc private func copyAction() { actionHandler?.toolbarCopy() }
    @objc private func saveAction() { actionHandler?.toolbarSave() }
    @objc private func pinAction() { actionHandler?.toolbarPin() }
}

import AppKit
import Foundation

@MainActor
protocol PinAnnotateToolbarDelegate: AnyObject {
    func pinToolbarSelectTool(_ tool: CaptureAnnotateTool?)
    func pinToolbarSelectShapeStyle(_ style: CaptureShapeStyle)
    func pinToolbarSelectArrowStyle(_ style: CaptureArrowStyle)
    func pinToolbarSelectMosaicStyle(_ style: CaptureMosaicStyle)
    func pinToolbarSelectPenStyle(_ style: CapturePenStyle)
    func pinToolbarUndo()
    func pinToolbarRedo()
    func pinToolbarDone()
    func pinToolbarCancel()
}

/// 贴图底部标注条：仅标注子集 + 完成/取消。
@MainActor
final class PinAnnotateToolbar: NSPanel {
    weak var actionHandler: PinAnnotateToolbarDelegate?

    private let buttonSize: CGFloat = 30
    private let rowHeight: CGFloat = 40
    private let sidePad: CGFloat = 10
    private let gap: CGFloat = 8
    private let barWidth: CGFloat = 420
    private let subRowExtra: CGFloat = 34
    private let dividerHeight: CGFloat = 1
    private let selectionGap: CGFloat = 12

    private var selectedTool: CaptureAnnotateTool?
    private var shapeStyle: CaptureShapeStyle = .rect
    private var arrowStyle: CaptureArrowStyle = .arrow
    private var mosaicStyle: CaptureMosaicStyle = .mosaic
    private var penStyle: CapturePenStyle = .pen

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

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: barWidth, height: rowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let chrome = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: barWidth, height: rowHeight))
        chrome.material = .popover
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.appearance = NSAppearance(named: .vibrantLight)
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 10
        chrome.layer?.masksToBounds = true
        chrome.autoresizingMask = [.width, .height]

        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.alignment = .leading
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(rootStack)

        row1.orientation = .horizontal
        row1.spacing = gap
        row1.alignment = .centerY
        row1.edgeInsets = NSEdgeInsets(top: 5, left: sidePad, bottom: 5, right: sidePad)
        row1.translatesAutoresizingMaskIntoConstraints = false

        row2.orientation = .horizontal
        row2.spacing = gap
        row2.alignment = .centerY
        row2.edgeInsets = NSEdgeInsets(top: 4, left: sidePad, bottom: 5, right: sidePad)
        row2.isHidden = true
        row2.translatesAutoresizingMaskIntoConstraints = false

        for tool in CaptureAnnotateTool.allCases {
            let b: NSButton
            if tool == .text {
                b = glyphBtn("T", tip: tool.tip, tag: tool.rawValue)
            } else {
                b = iconBtn(symbol(for: tool), tip: tool.tip, tag: tool.rawValue)
            }
            toolButtons[tool] = b
            row1.addArrangedSubview(b)
        }
        row1.addArrangedSubview(sep())
        row1.addArrangedSubview(actionBtn("arrow.uturn.backward", tip: "撤销", #selector(undoAction)))
        row1.addArrangedSubview(actionBtn("arrow.uturn.forward", tip: "重做", #selector(redoAction)))
        row1.addArrangedSubview(sep())
        row1.addArrangedSubview(actionBtn("checkmark", tip: "完成", #selector(doneAction)))
        row1.addArrangedSubview(actionBtn("xmark", tip: "取消", #selector(cancelAction)))

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
        hideAllSubs()

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: dividerHeight).isActive = true
        divider.isHidden = true

        rootStack.addArrangedSubview(row1)
        rootStack.addArrangedSubview(divider)
        rootStack.addArrangedSubview(row2)
        contentView = chrome

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: chrome.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
            row1.widthAnchor.constraint(equalToConstant: barWidth),
            row2.widthAnchor.constraint(equalToConstant: barWidth),
        ])
        refreshSelectionUI()
    }

    var barHeight: CGFloat {
        row2.isHidden ? rowHeight : rowHeight + dividerHeight + subRowExtra
    }

    func place(under pinFrame: CGRect) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(pinFrame) })?.frame
            ?? NSScreen.main?.frame
            ?? pinFrame
        let h = barHeight
        let w = barWidth
        var x = pinFrame.midX - w / 2
        var y = pinFrame.minY - h - selectionGap
        if y < screen.minY + 2 {
            y = min(pinFrame.maxY + selectionGap, screen.maxY - h - 2)
        }
        x = min(max(x, screen.minX + 2), screen.maxX - w - 2)
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        orderFrontRegardless()
    }

    private func configureSubStack(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.spacing = gap
        stack.alignment = .centerY
    }

    private func hideAllSubs() {
        shapeSubStack.isHidden = true
        arrowSubStack.isHidden = true
        penSubStack.isHidden = true
        mosaicSubStack.isHidden = true
        row2.isHidden = true
    }

    private func refreshSelectionUI() {
        let idle = NSColor(calibratedWhite: 0.2, alpha: 1)
        for (t, b) in toolButtons {
            let on = t == selectedTool
            b.state = on ? .on : .off
            b.contentTintColor = on ? .controlAccentColor : idle
            if t == .text {
                b.attributedTitle = NSAttributedString(
                    string: "T",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                        .foregroundColor: on ? NSColor.controlAccentColor : idle,
                    ]
                )
            }
        }
        hideAllSubs()
        switch selectedTool {
        case .shape:
            row2.isHidden = false
            shapeSubStack.isHidden = false
            rectButton.contentTintColor = shapeStyle == .rect ? .controlAccentColor : idle
            ellipseButton.contentTintColor = shapeStyle == .ellipse ? .controlAccentColor : idle
        case .arrow:
            row2.isHidden = false
            arrowSubStack.isHidden = false
            lineModeButton.contentTintColor = arrowStyle == .line ? .controlAccentColor : idle
            arrowModeButton.contentTintColor = arrowStyle == .arrow ? .controlAccentColor : idle
        case .pen:
            row2.isHidden = false
            penSubStack.isHidden = false
            penModeButton.contentTintColor = penStyle == .pen ? .controlAccentColor : idle
            markerModeButton.contentTintColor = penStyle == .marker ? .controlAccentColor : idle
            eraserModeButton.contentTintColor = penStyle == .eraser ? .controlAccentColor : idle
        case .mosaic:
            row2.isHidden = false
            mosaicSubStack.isHidden = false
            mosaicModeButton.contentTintColor = mosaicStyle == .mosaic ? .controlAccentColor : idle
            blurModeButton.contentTintColor = mosaicStyle == .blur ? .controlAccentColor : idle
        default:
            break
        }
        let h = barHeight
        setFrame(NSRect(x: frame.origin.x, y: frame.maxY - h, width: barWidth, height: h), display: true)
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
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.image?.isTemplate = true
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.tag = tag
        b.target = self
        b.action = #selector(toolAction(_:))
        b.setButtonType(.toggle)
        b.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        b.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
        return b
    }

    private func glyphBtn(_ title: String, tip: String, tag: Int) -> NSButton {
        let b = NSButton(frame: NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize))
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.title = title
        b.toolTip = tip
        b.tag = tag
        b.target = self
        b.action = #selector(toolAction(_:))
        b.setButtonType(.toggle)
        b.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        b.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
        return b
    }

    private func actionBtn(_ symbol: String, tip: String, _ sel: Selector) -> NSButton {
        let b = iconBtn(symbol, tip: tip, tag: -1)
        b.setButtonType(.momentaryChange)
        b.action = sel
        return b
    }

    private func sep() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    @objc private func toolAction(_ sender: NSButton) {
        guard let tool = CaptureAnnotateTool(rawValue: sender.tag) else { return }
        if selectedTool == tool {
            selectedTool = nil
            actionHandler?.pinToolbarSelectTool(nil)
        } else {
            selectedTool = tool
            actionHandler?.pinToolbarSelectTool(tool)
            switch tool {
            case .shape: actionHandler?.pinToolbarSelectShapeStyle(shapeStyle)
            case .arrow: actionHandler?.pinToolbarSelectArrowStyle(arrowStyle)
            case .pen: actionHandler?.pinToolbarSelectPenStyle(penStyle)
            case .mosaic: actionHandler?.pinToolbarSelectMosaicStyle(mosaicStyle)
            case .text: break
            }
        }
        refreshSelectionUI()
    }

    @objc private func shapeStyleAction(_ sender: NSButton) {
        shapeStyle = sender.tag == 101 ? .ellipse : .rect
        selectedTool = .shape
        actionHandler?.pinToolbarSelectShapeStyle(shapeStyle)
        refreshSelectionUI()
    }

    @objc private func arrowStyleAction(_ sender: NSButton) {
        arrowStyle = sender.tag == 110 ? .line : .arrow
        selectedTool = .arrow
        actionHandler?.pinToolbarSelectArrowStyle(arrowStyle)
        refreshSelectionUI()
    }

    @objc private func penStyleAction(_ sender: NSButton) {
        switch sender.tag {
        case 121: penStyle = .marker
        case 122: penStyle = .eraser
        default: penStyle = .pen
        }
        selectedTool = .pen
        actionHandler?.pinToolbarSelectPenStyle(penStyle)
        refreshSelectionUI()
    }

    @objc private func mosaicStyleAction(_ sender: NSButton) {
        mosaicStyle = sender.tag == 201 ? .blur : .mosaic
        selectedTool = .mosaic
        actionHandler?.pinToolbarSelectMosaicStyle(mosaicStyle)
        refreshSelectionUI()
    }

    @objc private func undoAction() { actionHandler?.pinToolbarUndo() }
    @objc private func redoAction() { actionHandler?.pinToolbarRedo() }
    @objc private func doneAction() { actionHandler?.pinToolbarDone() }
    @objc private func cancelAction() { actionHandler?.pinToolbarCancel() }
}

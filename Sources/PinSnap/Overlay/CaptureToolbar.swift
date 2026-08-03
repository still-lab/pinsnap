import AppKit
import Foundation

enum CaptureAnnotateTool: Int, CaseIterable {
    case shape
    case arrow
    case pen
    case mosaic
    case text

    var tip: String {
        switch self {
        case .shape: return "形状"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        }
    }
}

enum CaptureShapeStyle: Int {
    case rect
    case ellipse
}

@MainActor
protocol CaptureToolbarDelegate: AnyObject {
    func toolbarSelectTool(_ tool: CaptureAnnotateTool?)
    func toolbarSelectShapeStyle(_ style: CaptureShapeStyle)
    func toolbarUndo()
    func toolbarCopy()
    func toolbarSave()
    func toolbarPin()
    func toolbarClose()
}

/// 两层工具条：默认一层；点「形状」后出第二层选矩形/椭圆。
@MainActor
final class CaptureToolbar: NSPanel {
    weak var actionHandler: CaptureToolbarDelegate?

    private let buttonSize: CGFloat = 30
    private let rowHeight: CGFloat = 40
    private let sidePad: CGFloat = 10
    private let gap: CGFloat = 8

    private var selectedTool: CaptureAnnotateTool?
    private var shapeStyle: CaptureShapeStyle = .rect

    private let rootStack = NSStackView()
    private let row1 = NSStackView()
    private let row2 = NSStackView()
    private var toolButtons: [CaptureAnnotateTool: NSButton] = [:]
    private var rectButton: NSButton!
    private var ellipseButton: NSButton!

    private let barWidth: CGFloat = 420

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: rowHeight),
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

        let blur = NSVisualEffectView(frame: .zero)
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false

        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.alignment = .leading
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(rootStack)

        row1.orientation = .horizontal
        row1.spacing = gap
        row1.alignment = .centerY
        row1.edgeInsets = NSEdgeInsets(top: 5, left: sidePad, bottom: 5, right: sidePad)

        row2.orientation = .horizontal
        row2.spacing = gap
        row2.alignment = .centerY
        row2.edgeInsets = NSEdgeInsets(top: 0, left: sidePad, bottom: 5, right: sidePad)
        row2.isHidden = true

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
        row1.addArrangedSubview(sep())
        row1.addArrangedSubview(actionBtn("doc.on.doc", tip: "复制", #selector(copyAction)))
        row1.addArrangedSubview(actionBtn("square.and.arrow.down", tip: "保存", #selector(saveAction)))
        row1.addArrangedSubview(actionBtn("pin", tip: "贴图", #selector(pinAction)))
        row1.addArrangedSubview(actionBtn("xmark", tip: "关闭", #selector(closeAction)))

        // 第二层：矩形 / 椭圆
        rectButton = iconBtn("rectangle", tip: "矩形", tag: 100)
        rectButton.action = #selector(shapeStyleAction(_:))
        ellipseButton = iconBtn("oval", tip: "椭圆", tag: 101)
        ellipseButton.action = #selector(shapeStyleAction(_:))
        row2.addArrangedSubview(rectButton)
        row2.addArrangedSubview(ellipseButton)

        rootStack.addArrangedSubview(row1)
        rootStack.addArrangedSubview(row2)

        contentView = blur
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: blur.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        refreshHeight()
        refreshSelectionUI()
    }

    var width: CGFloat { barWidth }
    var height: CGFloat { row2.isHidden ? rowHeight : rowHeight + 34 }

    func setSelectedTool(_ tool: CaptureAnnotateTool?) {
        selectedTool = tool
        refreshSelectionUI()
    }

    func setShapeStyle(_ style: CaptureShapeStyle) {
        shapeStyle = style
        refreshSelectionUI()
    }

    func place(under selection: CGRect, inScreenBounds screen: CGRect) {
        refreshHeight()
        let h = height
        let w = barWidth
        var x = selection.midX - w / 2
        var y = selection.minY - h - 2
        if y < screen.minY + 2 {
            y = min(selection.maxY + 2, screen.maxY - h - 2)
        }
        x = min(max(x, screen.minX + 2), screen.maxX - w - 2)
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        orderFrontRegardless()
    }

    private func refreshHeight() {
        let h = height
        setContentSize(NSSize(width: barWidth, height: h))
        contentView?.setFrameSize(NSSize(width: barWidth, height: h))
    }

    private func refreshSelectionUI() {
        for (t, b) in toolButtons {
            let on = t == selectedTool
            b.state = on ? .on : .off
            b.contentTintColor = on ? .controlAccentColor : .labelColor
            if t == .text {
                b.attributedTitle = NSAttributedString(
                    string: "T",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                        .foregroundColor: on ? NSColor.controlAccentColor : NSColor.labelColor,
                    ]
                )
            }
        }
        let showShapeRow = selectedTool == .shape
        row2.isHidden = !showShapeRow
        rectButton.state = shapeStyle == .rect ? .on : .off
        ellipseButton.state = shapeStyle == .ellipse ? .on : .off
        rectButton.contentTintColor = shapeStyle == .rect ? .controlAccentColor : .labelColor
        ellipseButton.contentTintColor = shapeStyle == .ellipse ? .controlAccentColor : .labelColor
        refreshHeight()
    }

    private func symbol(for tool: CaptureAnnotateTool) -> String {
        switch tool {
        case .shape: return "rectangle.on.rectangle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .mosaic: return "square.grid.3x3.fill"
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
        b.contentTintColor = .labelColor
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: buttonSize),
            b.heightAnchor.constraint(equalToConstant: buttonSize),
        ])
        return b
    }

    private func glyphBtn(_ glyph: String, tip: String, tag: Int) -> NSButton {
        let b = iconBtn("circle", tip: tip, tag: tag)
        b.image = nil
        b.attributedTitle = NSAttributedString(
            string: glyph,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
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
        v.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 18),
        ])
        return v
    }

    @objc private func toolAction(_ sender: NSButton) {
        guard let tool = CaptureAnnotateTool(rawValue: sender.tag) else { return }
        if selectedTool == tool {
            selectedTool = nil
            actionHandler?.toolbarSelectTool(nil)
        } else {
            selectedTool = tool
            actionHandler?.toolbarSelectTool(tool)
            if tool == .shape {
                actionHandler?.toolbarSelectShapeStyle(shapeStyle)
            }
        }
        refreshSelectionUI()
        // 高度变化后由外部 place 更稳妥；这里尽量自适配
        if let screen = NSScreen.main {
            let f = frame
            setFrame(NSRect(x: f.origin.x, y: f.origin.y, width: barWidth, height: height), display: true)
            _ = screen
        }
    }

    @objc private func shapeStyleAction(_ sender: NSButton) {
        shapeStyle = sender.tag == 101 ? .ellipse : .rect
        selectedTool = .shape
        actionHandler?.toolbarSelectTool(.shape)
        actionHandler?.toolbarSelectShapeStyle(shapeStyle)
        refreshSelectionUI()
    }

    @objc private func undoAction() { actionHandler?.toolbarUndo() }
    @objc private func copyAction() { actionHandler?.toolbarCopy() }
    @objc private func saveAction() { actionHandler?.toolbarSave() }
    @objc private func pinAction() { actionHandler?.toolbarPin() }
    @objc private func closeAction() { actionHandler?.toolbarClose() }
}

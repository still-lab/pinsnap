import AppKit
import Foundation

/// 长截操作条：自动滚动 / 完成 / 取消（样式对齐 `CaptureToolbar`）。
@MainActor
final class ScrollCaptureDoneBar: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleAutoScroll: (() -> Void)?

    private let buttonSize: CGFloat = 26
    private let barHeight: CGFloat = 34
    private let sidePad: CGFloat = 6
    private let gap: CGFloat = 4
    private let selectionGap: CGFloat = 8
    private let idleTint = NSColor(calibratedWhite: 0.2, alpha: 1)

    private var barWidth: CGFloat {
        // 3 按钮 + 1 分隔 + 左右 padding + spacing
        sidePad * 2 + buttonSize * 3 + gap * 3 + 1
    }

    private var autoButton: NSButton?
    private var isAutoOn = false

    init() {
        let w = sidePad * 2 + buttonSize * 3 + gap * 3 + 1
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: w, height: barHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver + 3
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let chrome = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: barHeight))
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

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = gap
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 4, left: sidePad, bottom: 4, right: sidePad)
        row.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            row.topAnchor.constraint(equalTo: chrome.topAnchor),
            row.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
        ])

        let auto = actionBtn("arrow.down.to.line", tip: "自动滚动", #selector(autoClicked))
        auto.setButtonType(.toggle)
        autoButton = auto
        row.addArrangedSubview(auto)
        row.addArrangedSubview(sep())
        row.addArrangedSubview(actionBtn("checkmark", tip: "完成", #selector(doneClicked)))
        row.addArrangedSubview(actionBtn("xmark", tip: "取消", #selector(cancelClicked)))

        contentView = chrome
    }

    func setAutoScrolling(_ on: Bool) {
        isAutoOn = on
        let name = on ? "stop.fill" : "arrow.down.to.line"
        let tip = on ? "停止滚动" : "自动滚动"
        autoButton?.image = NSImage(systemSymbolName: name, accessibilityDescription: tip)
        autoButton?.image?.isTemplate = true
        autoButton?.toolTip = tip
        autoButton?.state = on ? .on : .off
        autoButton?.contentTintColor = on ? .controlAccentColor : idleTint
    }

    func place(near selection: CGRect, inScreenBounds screen: CGRect) {
        let w = barWidth
        let h = barHeight
        var x = selection.midX - w / 2
        var y = selection.minY - h - selectionGap
        if y < screen.minY + 2 {
            y = min(selection.maxY + selectionGap, screen.maxY - h - 2)
        }
        x = min(max(x, screen.minX + 2), screen.maxX - w - 2)
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        orderFrontRegardless()
    }

    private func actionBtn(_ symbol: String, tip: String, _ sel: Selector) -> NSButton {
        let b = NSButton(frame: NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize))
        b.bezelStyle = .shadowlessSquare
        b.isBordered = false
        b.setButtonType(.momentaryLight)
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.image?.isTemplate = true
        b.contentTintColor = idleTint
        b.toolTip = tip
        b.target = self
        b.action = sel
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: buttonSize),
            b.heightAnchor.constraint(equalToConstant: buttonSize),
        ])
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

    @objc private func doneClicked() { onDone?() }
    @objc private func cancelClicked() { onCancel?() }
    @objc private func autoClicked() { onToggleAutoScroll?() }
}

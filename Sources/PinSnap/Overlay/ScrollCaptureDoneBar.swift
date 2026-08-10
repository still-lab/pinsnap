import AppKit
import Foundation

/// 长截进行中的操作条：样式对齐 CaptureToolbar（毛玻璃 + 图标按钮）。
@MainActor
final class ScrollCaptureDoneBar: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private let buttonSize: CGFloat = 30
    private let barHeight: CGFloat = 40
    private let barWidth: CGFloat = 96

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: barWidth, height: barHeight),
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

        let chrome = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: barWidth, height: barHeight))
        chrome.material = .popover
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.appearance = NSAppearance(named: .vibrantLight)
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 10
        chrome.layer?.masksToBounds = true
        chrome.layer?.borderWidth = 0.5
        chrome.layer?.borderColor = NSColor.white.withAlphaComponent(0.65).cgColor
        chrome.autoresizingMask = [.width, .height]

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            row.topAnchor.constraint(equalTo: chrome.topAnchor),
            row.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
        ])

        row.addArrangedSubview(iconButton("checkmark", tip: "完成", #selector(doneClicked)))
        row.addArrangedSubview(iconButton("xmark", tip: "取消", #selector(cancelClicked)))

        contentView = chrome
    }

    func place(near selection: CGRect, inScreenBounds screen: CGRect) {
        let w = barWidth
        let h = barHeight
        var x = selection.midX - w / 2
        var y = selection.minY - h - 12
        if y < screen.minY + 8 {
            y = min(selection.maxY + 12, screen.maxY - h - 8)
        }
        x = min(max(x, screen.minX + 8), screen.maxX - w - 8)
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        orderFrontRegardless()
    }

    private func iconButton(_ symbol: String, tip: String, _ selector: Selector) -> NSButton {
        let b = NSButton(frame: NSRect(x: 0, y: 0, width: buttonSize, height: buttonSize))
        b.bezelStyle = .shadowlessSquare
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyDown
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(cfg)
        b.contentTintColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        b.toolTip = tip
        b.target = self
        b.action = selector
        b.setButtonType(.momentaryChange)
        b.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        b.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
        return b
    }

    @objc private func doneClicked() { onDone?() }
    @objc private func cancelClicked() { onCancel?() }
}

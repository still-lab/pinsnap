import AppKit
import CoreGraphics
import Foundation

/// 长截侧栏：实时拼接预览 + 完成 / 取消。
@MainActor
final class ScrollCaptureHUD: NSPanel {
    var onComplete: (() -> Void)?
    var onCancel: (() -> Void)?

    private let chrome = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "滚动选区")
    private let completeButton = NSButton(title: "完成", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let rootStack = NSStackView()

    private let previewWidth: CGFloat = 168
    private let chromePad: CGFloat = 10
    private let buttonRowHeight: CGFloat = 36
    private var scrollHeightConstraint: NSLayoutConstraint?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 188, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver + 2
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false

        chrome.material = .popover
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 12
        chrome.layer?.masksToBounds = true
        chrome.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop
        imageView.animates = false

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = imageView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center

        completeButton.target = self
        completeButton.action = #selector(completeAction)
        completeButton.bezelStyle = .rounded
        completeButton.controlSize = .small
        completeButton.keyEquivalent = "\r"

        cancelButton.target = self
        cancelButton.action = #selector(cancelAction)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small

        let buttons = NSStackView(views: [cancelButton, completeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillEqually

        rootStack.orientation = .vertical
        rootStack.spacing = 8
        rootStack.edgeInsets = NSEdgeInsets(
            top: chromePad, left: chromePad, bottom: chromePad, right: chromePad
        )
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(statusLabel)
        rootStack.addArrangedSubview(scrollView)
        rootStack.addArrangedSubview(buttons)

        chrome.addSubview(rootStack)
        contentView = chrome

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: chrome.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: previewWidth),
        ])
    }

    func update(preview: CGImage?, frameCount: Int, status: String? = nil) {
        if let status {
            statusLabel.stringValue = status
        } else if frameCount <= 0 {
            statusLabel.stringValue = "采帧中"
        } else if frameCount == 1 {
            statusLabel.stringValue = "滚动选区"
        } else {
            statusLabel.stringValue = "\(frameCount) 帧"
        }
        guard let preview else {
            if frameCount == 0 { imageView.image = nil }
            return
        }
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
        let pointW = CGFloat(preview.width) / scale
        let pointH = CGFloat(preview.height) / scale
        let fitScale = previewWidth / max(pointW, 1)
        let displaySize = NSSize(width: previewWidth, height: max(1, pointH * fitScale))
        let nsImage = NSImage(cgImage: preview, size: displaySize)
        imageView.image = nsImage
        imageView.frame = NSRect(origin: .zero, size: displaySize)
        scrollView.layoutSubtreeIfNeeded()
        // 跟到底部，展示最新拼接
        if displaySize.height > scrollView.contentSize.height {
            let maxY = max(0, displaySize.height - scrollView.contentSize.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// 贴在选区右侧；空间不够则左侧；高度跟选区对齐并受屏高限制。
    func place(beside selection: CGRect, inScreenBounds screen: CGRect) {
        let panelW = previewWidth + chromePad * 2
        let maxH = min(screen.height - 24, max(selection.height, 220), 560)
        let panelH = maxH
        let gap: CGFloat = 12

        var x = selection.maxX + gap
        if x + panelW > screen.maxX - 8 {
            x = selection.minX - gap - panelW
        }
        if x < screen.minX + 8 {
            x = min(screen.maxX - panelW - 8, max(screen.minX + 8, selection.maxX + gap))
        }

        var y = selection.midY - panelH / 2
        y = min(max(y, screen.minY + 8), screen.maxY - panelH - 8)

        setFrame(NSRect(x: x, y: y, width: panelW, height: panelH), display: true)
        let minScrollH = max(80, panelH - chromePad * 2 - buttonRowHeight - 28)
        if let existing = scrollHeightConstraint {
            existing.constant = minScrollH
        } else {
            let c = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: minScrollH)
            c.isActive = true
            scrollHeightConstraint = c
        }
        orderFrontRegardless()
    }

    @objc private func completeAction() { onComplete?() }
    @objc private func cancelAction() { onCancel?() }
}

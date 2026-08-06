import AppKit
import Foundation

/// 长截滚动态选区描边：不挡内容，供 CG 以 belowWindow 穿透采帧。
@MainActor
final class ScrollSelectionRing: NSPanel {
    private let border = CAShapeLayer()

    init(selection: CGRect) {
        let pad: CGFloat = 3
        let frame = selection.insetBy(dx: -pad, dy: -pad)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver + 1
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.clear.cgColor

        border.fillColor = nil
        border.strokeColor = NSColor.systemRed.cgColor
        border.lineWidth = 2
        border.frame = view.bounds
        let inner = view.bounds.insetBy(dx: 1, dy: 1)
        border.path = CGPath(rect: inner, transform: nil)
        view.layer?.addSublayer(border)

        contentView = view
        setFrame(frame, display: true)
        orderFrontRegardless()
    }
}

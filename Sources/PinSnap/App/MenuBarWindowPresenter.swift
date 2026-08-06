import AppKit

/// 菜单栏 App（`.accessory` / LSUIElement）弹出普通 NSWindow 的可靠前置。
///
/// 仅 `makeKeyAndOrderFront` + `activate` 时，窗经常开在其它 App 背后，表现为「点了没反应」。
/// 需要临时升到 `.regular`，激活后再前置；最后一扇窗关闭后恢复 `.accessory`。
@MainActor
public final class MenuBarWindowPresenter: NSObject, NSWindowDelegate {
    public static let shared = MenuBarWindowPresenter()

    private var tracked = Set<ObjectIdentifier>()
    private var policyToRestore: NSApplication.ActivationPolicy?

    public func present(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        if window.delegate !== self {
            window.delegate = self
        }

        let current = NSApp.activationPolicy()
        if current != .regular {
            if policyToRestore == nil {
                policyToRestore = current
            }
            NSApp.setActivationPolicy(.regular)
        }

        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        tracked.insert(ObjectIdentifier(window))
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        tracked.remove(ObjectIdentifier(window))
        guard tracked.isEmpty, let policy = policyToRestore else { return }
        policyToRestore = nil
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}

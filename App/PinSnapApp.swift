import AppKit
import PinSnapKit
import SwiftUI

@main
@MainActor
final class PinSnapApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var permissionWindow: NSWindow?
    private var upgradeWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = PinSnapApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let boot = AppBootstrap.shared
        boot.presentPermission = { [weak self] in self?.showPermission() }
        boot.presentUpgrade = { [weak self] in self?.showUpgrade() }
        boot.presentSettings = { [weak self] in self?.showSettings() }
        boot.start()
        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppBootstrap.shared.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "PinSnap")
            button.image?.isTemplate = true
            button.toolTip = "PinSnap"
            button.target = self
            button.action = #selector(statusLeftClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusLeftClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            AppBootstrap.shared.coordinator.beginCapture()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu(sender)
        } else {
            AppBootstrap.shared.coordinator.beginCapture()
        }
    }

    private func showMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "截图", action: #selector(capture), keyEquivalent: "a").keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(withTitle: "贴图", action: #selector(paste), keyEquivalent: "v").keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(withTitle: "显示/隐藏贴图", action: #selector(togglePins), keyEquivalent: "h").keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "取消全部穿透", action: #selector(clearClickThrough), keyEquivalent: "")
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: FeatureGate.shared.isPro ? "管理 Pro…" : "升级 Pro…", action: #selector(openUpgrade), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 PinSnap", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func capture() { AppBootstrap.shared.coordinator.beginCapture() }
    @objc private func paste() { AppBootstrap.shared.coordinator.beginPasteFromClipboard() }
    @objc private func togglePins() { AppBootstrap.shared.coordinator.togglePinVisibility() }
    @objc private func clearClickThrough() { AppBootstrap.shared.pins.clearAllClickThrough() }
    @objc private func openSettings() { showSettings() }
    @objc private func openUpgrade() { showUpgrade() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsRootView()
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "PinSnap"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 460, height: 320))
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPermission() {
        let view = PermissionView(
            onOpenSettings: { ScreenPermission.openSystemSettings() },
            onLater: { [weak self] in self?.permissionWindow?.orderOut(nil) }
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "屏幕权限"
        window.styleMask = [.titled, .closable]
        permissionWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showUpgrade() {
        let hosting = NSHostingController(rootView: UpgradeView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "PinSnap Pro"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 360, height: 240))
        upgradeWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

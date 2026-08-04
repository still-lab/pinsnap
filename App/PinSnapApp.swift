import AppKit
import PinSnapKit
import SwiftUI

@main
@MainActor
final class PinSnapApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var upgradeWindow: NSWindow?
    private var menuBarImage: NSImage?

    static func main() {
        let app = NSApplication.shared
        let delegate = PinSnapApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let boot = AppBootstrap.shared
        boot.presentUpgrade = { [weak self] in self?.showUpgrade() }
        boot.presentSettings = { [weak self] in self?.showSettings() }
        boot.coordinator.onDelayCountdown = { [weak self] remaining in
            self?.updateDelayCountdown(remaining)
        }
        boot.start()
        setupStatusItem()

        if CommandLine.arguments.contains("--self-test-capture") {
            Task { @MainActor in
                await ScreenPermission.writeCaptureSelfTestReport()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppBootstrap.shared.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuBarImage = Self.loadMenuBarImage()
        if let button = item.button {
            button.image = menuBarImage
            button.image?.isTemplate = true
            button.toolTip = "PinSnap"
            button.title = ""
        }
        item.menu = buildStatusMenu()
        statusItem = item
    }

    private static func loadMenuBarImage() -> NSImage {
        if let named = NSImage(named: "MenuBarIcon") {
            named.isTemplate = true
            return named
        }
        let fallback = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PinSnap")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }

    private func updateDelayCountdown(_ remaining: Int?) {
        guard let button = statusItem?.button else { return }
        if let remaining {
            button.image = nil
            button.title = "\(remaining)"
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        } else {
            button.title = ""
            button.image = menuBarImage
            button.image?.isTemplate = true
        }
    }

    private func rebuildStatusMenu() {
        statusItem?.menu = buildStatusMenu()
    }

    /// 上动作、下逃逸；冷入口进设置。左键仅出菜单（不做单击截图）。
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(actionItem("截图", #selector(capture)))
        menu.addItem(actionItem("延时截图", #selector(captureDelayed)))
        let lastRegion = actionItem("上次区域", #selector(captureLastRegion))
        lastRegion.isEnabled = AppBootstrap.shared.coordinator.hasLastSelection
        menu.addItem(lastRegion)
        menu.addItem(actionItem("截图并复制", #selector(captureAutoCopy)))
        menu.addItem(.separator())

        menu.addItem(actionItem("贴图", #selector(paste)))
        menu.addItem(actionItem("隐藏/显示贴图", #selector(togglePins)))
        menu.addItem(.separator())

        let disableHotKeys = NSMenuItem(
            title: "禁用快捷键",
            action: #selector(toggleDisableHotKeys(_:)),
            keyEquivalent: ""
        )
        disableHotKeys.target = self
        disableHotKeys.state = AppBootstrap.shared.hotKeysDisabled ? .on : .off
        disableHotKeys.image = nil
        menu.addItem(disableHotKeys)
        menu.addItem(actionItem("设置", #selector(openSettings)))
        menu.addItem(actionItem(
            FeatureGate.shared.isPro ? "管理专业版…" : "解锁专业版…",
            #selector(openUpgrade)
        ))
        menu.addItem(.separator())
        menu.addItem(actionItem("退出", #selector(quit)))
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            // 系统可能给「设置」等项自动塞 SF Symbol，打开前清掉
            item.image = nil
            if item.action == #selector(captureLastRegion) {
                item.isEnabled = AppBootstrap.shared.coordinator.hasLastSelection
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            item.image = nil
        }
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.image = nil
        return item
    }

    @objc private func capture() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            AppBootstrap.shared.coordinator.beginCapture(autoCopy: false)
        }
    }

    @objc private func captureDelayed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            AppBootstrap.shared.coordinator.beginDelayedCapture(autoCopy: false)
        }
    }

    @objc private func captureLastRegion() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            AppBootstrap.shared.coordinator.beginCaptureLastRegion(autoCopy: false)
        }
    }

    @objc private func captureAutoCopy() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            AppBootstrap.shared.coordinator.beginCapture(autoCopy: true)
        }
    }

    @objc private func paste() {
        AppBootstrap.shared.coordinator.beginPasteFromClipboard()
    }

    @objc private func togglePins() {
        AppBootstrap.shared.coordinator.togglePinVisibility()
    }

    @objc private func toggleDisableHotKeys(_ sender: NSMenuItem) {
        AppBootstrap.shared.toggleHotKeysDisabled()
        rebuildStatusMenu()
    }

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

import AppKit
import PinSnapKit
import SwiftUI

@main
@MainActor
final class PinSnapApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
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
        boot.presentUpgrade = { [weak self] in self?.showUpgrade() }
        boot.presentSettings = { [weak self] in self?.showSettings() }
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
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "PinSnap")
            button.image?.isTemplate = true
            button.toolTip = "PinSnap"
        }
        item.menu = buildStatusMenu()
        statusItem = item
    }

    private func rebuildStatusMenu() {
        statusItem?.menu = buildStatusMenu()
    }

    /// 对标 Snipaste / iShot：分区下拉，不展示快捷键列。
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(actionItem("偏好设置", #selector(openSettings)))
        menu.addItem(.separator())

        menu.addItem(actionItem("截图", #selector(capture)))
        menu.addItem(actionItem("截图并自动复制", #selector(captureAutoCopy)))
        menu.addItem(actionItem("从剪切板贴图", #selector(paste)))
        menu.addItem(actionItem("隐藏/显示所有贴图", #selector(togglePins)))
        menu.addItem(actionItem("清空截屏历史", #selector(clearHistory)))
        menu.addItem(.separator())

        let disableHotKeys = NSMenuItem(
            title: "禁用快捷键",
            action: #selector(toggleDisableHotKeys(_:)),
            keyEquivalent: ""
        )
        disableHotKeys.target = self
        disableHotKeys.state = AppBootstrap.shared.hotKeysDisabled ? .on : .off
        menu.addItem(disableHotKeys)
        menu.addItem(.separator())

        menu.addItem(actionItem("打开最后保存目录", #selector(openLastSaveDir)))
        menu.addItem(actionItem(
            FeatureGate.shared.isPro ? "管理专业版…" : "解锁专业版…",
            #selector(openUpgrade)
        ))
        menu.addItem(.separator())

        menu.addItem(actionItem("退出", #selector(quit)))
        return menu
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func capture() {
        // 等菜单收起后再截帧，避免菜单残影 / 抢焦点导致遮罩收不到拖拽
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            AppBootstrap.shared.coordinator.beginCapture(autoCopy: false)
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

    @objc private func clearHistory() {
        AppBootstrap.shared.coordinator.clearCaptureHistory()
    }

    @objc private func toggleDisableHotKeys(_ sender: NSMenuItem) {
        AppBootstrap.shared.toggleHotKeysDisabled()
        rebuildStatusMenu()
    }

    @objc private func openLastSaveDir() {
        AppBootstrap.shared.coordinator.openLastSaveDirectory()
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

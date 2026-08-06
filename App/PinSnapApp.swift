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
    private var statusMenu: NSMenu?
    private var isShowingDelayCountdown = false

    static func main() {
        let app = NSApplication.shared
        let delegate = PinSnapApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS 26+ 会给「选项/设置」等标题自动塞齿轮；对本 App 关掉
        UserDefaults.standard.register(defaults: ["NSMenuEnableActionImages": false])

        let boot = AppBootstrap.shared
        boot.presentUpgrade = { [weak self] in self?.showUpgrade() }
        boot.presentSettings = { [weak self] in self?.showSettings() }
        boot.coordinator.onDelayCountdown = { [weak self] remaining in
            self?.updateDelayCountdown(remaining)
        }
        setupStatusItem()
        boot.start()

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
        menuBarImage = Self.loadMenuBarImage()

        // squareLength：即使瞬间没图也不会把槽位宽度塌成 0（看起来像「图标消失」）
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        // 不挂 statusItem.menu，避免系统往状态栏按钮塞齿轮
        item.menu = nil
        statusMenu = buildStatusMenu()
        applyStatusItemIcon()
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("PinSnap")
        }
        item.isVisible = true

        // 启动后系统偶发清掉 button.image；延后盖回
        for delay in [0.0, 0.2, 1.0] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applyStatusItemIcon()
            }
        }
    }

    /// 优先读独立 PNG（带 alpha 的模板图）；再退回 Assets / SF Symbol。
    private static func loadMenuBarImage() -> NSImage {
        let pointSize = NSSize(width: 18, height: 18)

        if let fromFiles = loadMenuBarPNGFiles() {
            let baked = bakeTemplate(fromFiles, pointSize: pointSize)
            PinSnapLog.app.info("MenuBarIcon from PNG files")
            return baked
        }
        if let named = NSImage(named: "MenuBarIcon") {
            let baked = bakeTemplate(named, pointSize: pointSize)
            PinSnapLog.app.info("MenuBarIcon from Assets.car")
            return baked
        }
        PinSnapLog.app.error("MenuBarIcon missing; fallback SF Symbol")
        let fallback = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PinSnap")
            ?? NSImage(size: pointSize)
        return bakeTemplate(fallback, pointSize: pointSize)
    }

    private static func loadMenuBarPNGFiles() -> NSImage? {
        let bundle = Bundle.main
        let candidates = [
            bundle.url(forResource: "icon_16", withExtension: "png", subdirectory: "MenuBar"),
            bundle.url(forResource: "icon_16", withExtension: "png"),
            bundle.resourceURL?.appendingPathComponent("MenuBar/icon_16.png"),
        ].compactMap { $0 }
        guard let url16 = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data16 = try? Data(contentsOf: url16),
              let rep16 = NSBitmapImageRep(data: data16) else {
            return nil
        }
        let img = NSImage()
        img.addRepresentation(rep16)
        let url32 = url16.deletingLastPathComponent().appendingPathComponent("icon_32.png")
        if let data32 = try? Data(contentsOf: url32),
           let rep32 = NSBitmapImageRep(data: data32) {
            img.addRepresentation(rep32)
        }
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    /// 画进固定尺寸的新 NSImage，并标成 template，避免 Assets.car 无 alpha / copy 丢 representation。
    private static func bakeTemplate(_ source: NSImage, pointSize: NSSize) -> NSImage {
        let baked = NSImage(size: pointSize, flipped: false) { rect in
            source.draw(
                in: rect,
                from: NSRect(origin: .zero, size: source.size),
                operation: .sourceOver,
                fraction: 1.0,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            return true
        }
        baked.isTemplate = true
        return baked
    }

    private func applyStatusItemIcon() {
        guard !isShowingDelayCountdown, let item = statusItem, let button = item.button else { return }
        guard let icon = menuBarImage else { return }
        item.length = NSStatusItem.squareLength
        button.title = ""
        button.image = icon
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "PinSnap"
        button.appearsDisabled = false
    }

    private func updateDelayCountdown(_ remaining: Int?) {
        guard let item = statusItem, let button = item.button, let icon = menuBarImage else { return }
        if let remaining {
            isShowingDelayCountdown = true
            // 绝不把 image 置 nil：置空后槽位/模板图容易「消失」，且系统可能短暂露出齿轮
            item.length = NSStatusItem.variableLength
            button.image = icon
            button.imagePosition = .imageLeading
            button.title = "\(remaining)"
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        } else {
            isShowingDelayCountdown = false
            button.title = ""
            applyStatusItemIcon()
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let menu = statusMenu else { return }
        refreshStatusMenu(menu)
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.height),
                in: button
            )
            self.applyStatusItemIcon()
        }
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(actionItem("截图", #selector(capture), shortcut: "F1"))
        menu.addItem(actionItem("延时截图", #selector(captureDelayed), shortcut: "⌘T"))
        let lastRegion = actionItem("上次区域", #selector(captureLastRegion), shortcut: "F1×2")
        lastRegion.isEnabled = AppBootstrap.shared.coordinator.hasLastSelection
        menu.addItem(lastRegion)
        menu.addItem(actionItem("截图并复制", #selector(captureAutoCopy)))
        menu.addItem(actionItem("截图并保存", #selector(captureAutoSave)))
        menu.addItem(.separator())

        menu.addItem(actionItem("贴图", #selector(paste), shortcut: "F3"))
        menu.addItem(actionItem("隐藏贴图", #selector(hidePins), shortcut: "⌘H"))
        menu.addItem(actionItem("显示贴图", #selector(showPins), shortcut: "⌘⇧H"))
        menu.addItem(.separator())

        let disableHotKeys = NSMenuItem(
            title: "禁用快捷键",
            action: #selector(toggleDisableHotKeys(_:)),
            keyEquivalent: ""
        )
        disableHotKeys.target = self
        disableHotKeys.state = AppBootstrap.shared.hotKeysDisabled ? .on : .off
        menu.addItem(disableHotKeys)
        menu.addItem(actionItem("选项", #selector(openSettings)))
        menu.addItem(actionItem(
            FeatureGate.shared.isPro ? "管理专业版…" : "解锁专业版…",
            #selector(openUpgrade)
        ))
        menu.addItem(.separator())
        menu.addItem(actionItem("退出", #selector(quit)))
        return menu
    }

    private func refreshStatusMenu(_ menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(captureLastRegion) {
                item.isEnabled = AppBootstrap.shared.coordinator.hasLastSelection
            }
            if item.action == #selector(toggleDisableHotKeys(_:)) {
                item.state = AppBootstrap.shared.hotKeysDisabled ? .on : .off
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatusMenu(menu)
    }

    /// `shortcut` 一律走同一套右侧文案（非系统键位解析），保证字号与样式一致；全局仍由 HotKeyCenter 触发。
    private func actionItem(
        _ title: String,
        _ selector: Selector,
        shortcut: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        if let shortcut {
            item.attributedTitle = Self.menuLabeledTitle(title, shortcut: shortcut)
        }
        return item
    }

    private static func menuLabeledTitle(_ title: String, shortcut: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let color = NSColor.labelColor
        let shortcutColor = NSColor.secondaryLabelColor

        // 右对齐制表位：左侧标题、右侧快捷键同一字号
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 168, options: [:])]
        style.lineBreakMode = .byClipping

        let text = "\(title)\t\(shortcut)"
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
        let shortcutRange = NSRange(location: (title as NSString).length + 1, length: (shortcut as NSString).length)
        result.addAttributes([
            .font: font,
            .foregroundColor: shortcutColor,
        ], range: shortcutRange)
        return result
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

    @objc private func captureAutoSave() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            AppBootstrap.shared.coordinator.beginCapture(autoSave: true)
        }
    }

    @objc private func paste() {
        AppBootstrap.shared.coordinator.beginPasteFromClipboard()
    }

    @objc private func togglePins() {
        AppBootstrap.shared.coordinator.togglePinVisibility()
    }

    @objc private func hidePins() {
        AppBootstrap.shared.coordinator.hideAllPins()
    }

    @objc private func showPins() {
        AppBootstrap.shared.coordinator.showAllPins()
    }

    @objc private func toggleDisableHotKeys(_ sender: NSMenuItem) {
        AppBootstrap.shared.toggleHotKeysDisabled()
        sender.state = AppBootstrap.shared.hotKeysDisabled ? .on : .off
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
            window.setContentSize(NSSize(width: 520, height: 360))
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

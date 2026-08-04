import AppKit
import Foundation

/// 应用入口编排。
@MainActor
public final class AppBootstrap {
    public static let shared = AppBootstrap()

    private static let hotKeysDisabledKey = "pinsnap.hotKeysDisabled"

    public private(set) lazy var gate = FeatureGate.shared
    public private(set) lazy var pins = PinStore(gate: gate)
    public private(set) lazy var coordinator = SessionCoordinator(
        capture: CaptureService(),
        pins: pins,
        export: ImageExporter(),
        gate: gate
    )
    public private(set) lazy var hotKeys = HotKeyCenter()
    public var presentUpgrade: (() -> Void)?
    public var presentSettings: (() -> Void)?

    /// `true` = 全局快捷键关闭（菜单「禁用快捷键」勾选）。默认关闭快捷键，菜单功能仍可用。
    public private(set) var hotKeysDisabled: Bool {
        didSet { UserDefaults.standard.set(hotKeysDisabled, forKey: Self.hotKeysDisabledKey) }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.hotKeysDisabledKey) == nil {
            hotKeysDisabled = true
        } else {
            hotKeysDisabled = UserDefaults.standard.bool(forKey: Self.hotKeysDisabledKey)
        }
    }

    public func start() {
        ScreenPermission.noteLaunch()
        coordinator.onFreeLimit = { [weak self] in self?.presentUpgrade?() }
        hotKeys.onAction = { [weak self] action in
            guard let self, !self.hotKeysDisabled else { return }
            switch action {
            case .capture:
                self.coordinator.beginCapture()
            case .captureLastRegion:
                if self.coordinator.hasLastSelection {
                    self.coordinator.beginCaptureLastRegion()
                } else {
                    self.coordinator.beginCapture()
                }
            case .delayedCapture:
                self.coordinator.beginDelayedCapture()
            case .paste:
                self.coordinator.beginPasteFromClipboard()
            case .hidePins:
                self.coordinator.hideAllPins()
            case .showPins:
                self.coordinator.showAllPins()
            }
        }
        applyHotKeyRegistration()
        Task { await StoreClient.shared.refreshEntitlements() }
        // DEBUG 默认 Free，便于验 ≤3；升级页购买失败时可调试解锁
        PinSnapLog.app.info("PinSnap started (hotKeysDisabled=\(self.hotKeysDisabled))")
    }

    public func stop() {
        hotKeys.unregister()
    }

    public func setHotKeysDisabled(_ disabled: Bool) {
        hotKeysDisabled = disabled
        applyHotKeyRegistration()
    }

    public func toggleHotKeysDisabled() {
        setHotKeysDisabled(!hotKeysDisabled)
    }

    private func applyHotKeyRegistration() {
        hotKeys.unregister()
        guard !hotKeysDisabled else {
            PinSnapLog.app.info("Hotkeys disabled")
            return
        }
        do {
            try hotKeys.register()
        } catch {
            PinSnapLog.app.error("hotkey: \(error.localizedDescription)")
        }
    }
}

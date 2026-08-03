import AppKit
import Foundation

/// 应用入口编排。
@MainActor
public final class AppBootstrap {
    public static let shared = AppBootstrap()

    public private(set) lazy var gate = FeatureGate.shared
    public private(set) lazy var pins = PinStore(gate: gate)
    public private(set) lazy var coordinator = SessionCoordinator(
        capture: CaptureService(),
        pins: pins,
        export: ImageExporter(),
        gate: gate
    )
    public private(set) lazy var hotKeys = HotKeyCenter()
    public var presentPermission: (() -> Void)?
    public var presentUpgrade: (() -> Void)?
    public var presentSettings: (() -> Void)?

    private init() {}

    public func start() {
        coordinator.onNeedPermission = { [weak self] in self?.presentPermission?() }
        coordinator.onFreeLimit = { [weak self] in self?.presentUpgrade?() }
        hotKeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .capture: self.coordinator.beginCapture()
            case .paste: self.coordinator.beginPasteFromClipboard()
            case .togglePins: self.coordinator.togglePinVisibility()
            }
        }
        do {
            try hotKeys.register()
        } catch {
            PinSnapLog.app.error("hotkey: \(error.localizedDescription)")
        }
        coordinator.restorePins()
        Task { await StoreClient.shared.refreshEntitlements() }
        PinSnapLog.app.info("PinSnap started")
    }

    public func stop() {
        hotKeys.unregister()
    }
}

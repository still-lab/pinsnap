import Foundation
import ServiceManagement

/// 登录时启动。以 `SMAppService.mainApp.status` 为准，不另存 UserDefaults。
/// REQ: S-05 / F-081
@MainActor
public final class LaunchAtLogin: ObservableObject {
    public static let shared = LaunchAtLogin()

    @Published public private(set) var isEnabled: Bool

    private init() {
        isEnabled = Self.readEnabled()
    }

    public func refresh() {
        isEnabled = Self.readEnabled()
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                switch SMAppService.mainApp.status {
                case .enabled:
                    refresh()
                    return
                case .requiresApproval:
                    SMAppService.openSystemSettingsLoginItems()
                    refresh()
                    return
                default:
                    try SMAppService.mainApp.register()
                }
            } else {
                guard SMAppService.mainApp.status != .notRegistered else {
                    refresh()
                    return
                }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            PinSnapLog.app.error("launchAtLogin: \(error.localizedDescription)")
        }

        refresh()
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private static func readEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
}

import AppKit
import SwiftUI

/// 应用入口占位。M0 在 Xcode 工程中改为 @main 并挂 MenuBar。
/// REQ: S-01
@MainActor
public final class AppBootstrap {
    public static let shared = AppBootstrap()

    public private(set) lazy var coordinator = SessionCoordinator(
        capture: CaptureService(),
        pins: PinStore(gate: FeatureGate.shared),
        export: ImageExporter(),
        gate: FeatureGate.shared
    )

    public private(set) lazy var hotKeys = HotKeyCenter(coordinator: coordinator)

    private init() {}

    public func start() {
        // M0: 注册热键、检查权限状态、恢复 Pin 会话
    }
}

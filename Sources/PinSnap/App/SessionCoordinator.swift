import Foundation

/// 截图会话编排。驱动状态机并连接 Capture / Overlay / Annotate / Pin / Export。
/// REQ: C-05, S-02
@MainActor
public final class SessionCoordinator {
    public private(set) var state: CaptureSessionState = .idle

    private let capture: CaptureServiceProtocol
    private let pins: PinStoreProtocol
    private let export: ImageExporterProtocol
    private let gate: FeatureGateProtocol

    public init(
        capture: CaptureServiceProtocol,
        pins: PinStoreProtocol,
        export: ImageExporterProtocol,
        gate: FeatureGateProtocol
    ) {
        self.capture = capture
        self.pins = pins
        self.export = export
        self.gate = gate
    }

    public func beginCapture() async {
        guard state == .idle else { return }
        state = .preparing
        // M0–M1: 权限检查 → capturing → 展示 Overlay
    }

    public func beginPasteFromClipboard() {
        // M2: ClipboardBridge → PinStore.create
    }

    public func togglePinVisibility() {
        // M3: hideAll / showAll
    }
}

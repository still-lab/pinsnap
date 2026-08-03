import AppKit
import Foundation

/// 截图会话编排。
@MainActor
public final class SessionCoordinator {
    public private(set) var state: CaptureSessionState = .idle

    private let capture: CaptureServiceProtocol
    private let pins: PinStoreProtocol
    private let export: ImageExporterProtocol
    private let gate: FeatureGateProtocol
    private let clipboard = ClipboardBridge()
    private let overlay = CaptureOverlayController()
    private var lastSelectionImage: CGImage?

    public var onNeedPermission: (() -> Void)?
    public var onFreeLimit: (() -> Void)?

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
        overlay.onFinish = { [weak self] outcome in
            self?.handleOverlay(outcome)
        }
        overlay.onNeedUpgrade = { [weak self] in
            self?.onFreeLimit?()
        }
    }

    public func beginCapture(autoCopy: Bool = false) {
        Task { await beginCaptureAsync(autoCopy: autoCopy) }
    }

    public func beginCaptureAsync(autoCopy: Bool = false) async {
        guard state == .idle || state == .preparing else { return }
        state = .preparing
        if !ScreenPermission.isTrusted() {
            _ = ScreenPermission.requestAccess()
            if !ScreenPermission.isTrusted() {
                state = .idle
                onNeedPermission?()
                return
            }
        }
        do {
            state = .capturing
            let frames = try await capture.captureStillFrames()
            overlay.autoCopyOnSelect = autoCopy
            overlay.present(frames: frames)
        } catch CaptureError.permissionDenied {
            state = .idle
            onNeedPermission?()
        } catch {
            state = .idle
            Toast.shared.show(error.localizedDescription)
            PinSnapLog.capture.error("capture failed: \(error.localizedDescription)")
        }
    }

    public func clearCaptureHistory() {
        lastSelectionImage = nil
        Toast.shared.show("已清空")
    }

    public func openLastSaveDirectory() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        NSWorkspace.shared.open(dir)
    }

    public func beginPasteFromClipboard() {
        do {
            let content = try clipboard.resolve()
            let image: CGImage
            switch content {
            case .image(let i), .textRendered(let i), .colorCard(let i, _):
                image = i
            }
            _ = try pins.create(image: image, at: nil)
            Toast.shared.show("已贴图")
        } catch let error as PinStoreError {
            if case .freeLimitReached = error {
                onFreeLimit?()
            } else {
                Toast.shared.show(error.localizedDescription)
            }
        } catch {
            Toast.shared.show(error.localizedDescription)
        }
    }

    public func togglePinVisibility() {
        pins.toggleVisibility()
    }

    public func restorePins() {
        Task { try? await pins.restoreSession() }
    }

    private func handleOverlay(_ outcome: CaptureOverlayOutcome) {
        state = .committing
        switch outcome {
        case .cancelled:
            break
        case .copied(let image):
            lastSelectionImage = image
            Toast.shared.show("已复制")
        case .saved(let image):
            lastSelectionImage = image
            Toast.shared.show("已保存")
        case .pinned(let image, let frame):
            lastSelectionImage = image
            do {
                _ = try pins.create(image: image, at: frame)
                Toast.shared.show("已贴图")
            } catch let error as PinStoreError {
                if case .freeLimitReached = error { onFreeLimit?() }
                else { Toast.shared.show(error.localizedDescription) }
            } catch {
                Toast.shared.show(error.localizedDescription)
            }
        }
        state = .idle
    }
}

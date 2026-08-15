import AppKit
import CoreGraphics
import Foundation

/// 截图会话编排。
@MainActor
public final class SessionCoordinator {
    /// REQ: C-11 — 延时秒数固定，菜单入口，不可配置。
    public static let delayCaptureSeconds: TimeInterval = 5

    public private(set) var state: CaptureSessionState = .idle

    private let capture: CaptureServiceProtocol
    private let pins: PinStoreProtocol
    private let export: ImageExporterProtocol
    private let gate: FeatureGateProtocol
    private let clipboard = ClipboardBridge()
    private let overlay = CaptureOverlayController()
    /// 成功截图后的上次选区（内存）。REQ: C-10 / D-067
    private var lastSelection: CaptureSelection?
    private var delayTask: Task<Void, Never>?
    /// 本进程最多打开一次系统设置，避免刷屏。
    private var didOpenScreenSettingsThisProcess = false

    public var onFreeLimit: (() -> Void)?
    /// 延时倒计时：剩余秒数；`nil` 表示结束或取消。菜单栏显示数字。
    public var onDelayCountdown: ((Int?) -> Void)?

    public var hasLastSelection: Bool { lastSelection != nil }

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
        overlay.onScrollCaptureActiveChange = { [weak self] active in
            guard let self else { return }
            if active {
                self.state = .scrollCapturing
            } else if self.state == .scrollCapturing || self.state == .stitching {
                self.state = .annotating
            }
        }
        overlay.captureRegion = { [capture] selection, excludeIDs in
            try await capture.captureRegion(selection, excludingWindowIDs: excludeIDs)
        }
    }

    public func beginCapture(autoCopy: Bool = false, autoSave: Bool = false) {
        cancelDelay()
        Task { await beginCaptureAsync(autoCopy: autoCopy, autoSave: autoSave, initialSelection: nil, scrollAfterSelect: false) }
    }

    /// 长截图：框选后进入滚动采集。
    public func beginScrollCapture() {
        cancelDelay()
        Task { await beginCaptureAsync(autoCopy: false, autoSave: false, initialSelection: nil, scrollAfterSelect: true) }
    }

    /// REQ: C-11 — 固定延时后进入普通截图；菜单栏逐秒倒计时。
    public func beginDelayedCapture(autoCopy: Bool = false, autoSave: Bool = false) {
        cancelDelay()
        guard gate.isEnabled(.delayCapture) else { return }
        guard state == .idle || state == .preparing else { return }
        state = .preparing
        let total = Int(Self.delayCaptureSeconds)
        delayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: total, through: 1, by: -1) {
                guard !Task.isCancelled, self.state == .preparing else {
                    self.onDelayCountdown?(nil)
                    return
                }
                self.onDelayCountdown?(remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, self.state == .preparing else {
                self.onDelayCountdown?(nil)
                return
            }
            self.onDelayCountdown?(nil)
            self.delayTask = nil
            await self.beginCaptureAsync(autoCopy: autoCopy, autoSave: autoSave, initialSelection: nil, scrollAfterSelect: false)
        }
    }

    /// REQ: C-10 — 用内存中上次成功选区直接锁定选区。
    public func beginCaptureLastRegion(autoCopy: Bool = false, autoSave: Bool = false) {
        cancelDelay()
        guard let lastSelection else { return }
        Task { await beginCaptureAsync(autoCopy: autoCopy, autoSave: autoSave, initialSelection: lastSelection, scrollAfterSelect: false) }
    }

    public func beginCaptureAsync(
        autoCopy: Bool = false,
        autoSave: Bool = false,
        initialSelection: CaptureSelection? = nil,
        scrollAfterSelect: Bool = false
    ) async {
        guard state == .idle || state == .preparing else { return }
        state = .preparing

        // 未授权时主动弹出系统「屏幕录制」权限框；拒绝后再深链设置（本进程一次）。
        if !ScreenPermission.ensureReadyForCapture(openSettingsIfDenied: !didOpenScreenSettingsThisProcess) {
            if !CGPreflightScreenCaptureAccess() {
                didOpenScreenSettingsThisProcess = true
            }
            state = .idle
            Toast.shared.show("需要屏幕录制权限")
            return
        }

        do {
            state = .capturing
            let frames = try await capture.captureStillFrames()
            overlay.autoCopyOnSelect = autoCopy
            overlay.autoSaveOnSelect = autoSave && !autoCopy
            // 必须经 present 传入：present→dismiss 会清掉属性上的 flag
            overlay.present(
                frames: frames,
                initialSelection: initialSelection,
                enterScrollAfterSelect: scrollAfterSelect
            )
            if initialSelection != nil, !scrollAfterSelect {
                state = .annotating
            }
        } catch CaptureError.permissionDenied {
            state = .idle
            PinSnapLog.capture.error("capture permissionDenied")
            if !didOpenScreenSettingsThisProcess {
                didOpenScreenSettingsThisProcess = true
                ScreenPermission.openSystemSettings()
            }
        } catch {
            state = .idle
            PinSnapLog.capture.error("capture failed: \(error.localizedDescription)")
        }
    }

    public func clearCaptureHistory() {
        lastSelection = nil
    }

    public func openLastSaveDirectory() {
        SavePreferences.openDefaultDirectoryInFinder()
    }

    public func beginPasteFromClipboard() {
        do {
            let content = try clipboard.resolve()
            let image: CGImage
            switch content {
            case .image(let i), .textRendered(let i), .colorCard(let i, _):
                image = i
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.pins.create(image: image, at: nil)
                } catch let error as PinStoreError {
                    if case .freeLimitReached = error { self.onFreeLimit?() }
                    else { PinSnapLog.pin.error("paste: \(error.localizedDescription)") }
                } catch {
                    PinSnapLog.pin.error("paste: \(error.localizedDescription)")
                }
            }
        } catch let error as PinStoreError {
            if case .freeLimitReached = error {
                onFreeLimit?()
            }
            PinSnapLog.pin.error("paste: \(error.localizedDescription)")
        } catch {
            PinSnapLog.pin.error("paste: \(error.localizedDescription)")
        }
    }

    public func togglePinVisibility() {
        pins.toggleVisibility()
    }

    public func hideAllPins() {
        pins.hideAll()
    }

    public func showAllPins() {
        pins.showAll()
    }

    /// 从关闭栈恢复最近一张贴图（Snipaste 语义）。REQ: PIN_LIFECYCLE
    public func restoreLastClosedPin() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pins.restoreFromClosedIfNeeded()
        }
    }

    private func cancelDelay() {
        guard delayTask != nil else { return }
        delayTask?.cancel()
        delayTask = nil
        onDelayCountdown?(nil)
        if state == .preparing {
            state = .idle
        }
    }

    private func handleOverlay(_ outcome: CaptureOverlayOutcome) {
        state = .committing
        switch outcome {
        case .cancelled:
            break
        case .copied(_, let selection):
            lastSelection = selection
        case .saved(_, let selection):
            lastSelection = selection
        case .pinned(let image, let frame, let selection):
            lastSelection = selection
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.pins.create(image: image, at: frame)
                } catch let error as PinStoreError {
                    if case .freeLimitReached = error { self.onFreeLimit?() }
                    else { PinSnapLog.pin.error("\(error.localizedDescription)") }
                } catch {
                    PinSnapLog.pin.error("\(error.localizedDescription)")
                }
            }
        }
        state = .idle
    }
}

import AppKit
import Carbon
import Foundation

/// 全局热键。绑定来自 `HotKeyPreferences`；截图键连击派发上次区域。
@MainActor
public final class HotKeyCenter {
    public enum Action: UInt32 {
        case capture = 1
        case paste = 2
        case hidePins = 3
        case showPins = 4
        case captureLastRegion = 5
        case delayedCapture = 6
    }

    /// 单击与连击的判定窗。
    private static let doubleTapWindow: TimeInterval = 0.35

    public var onAction: ((Action) -> Void)?
    private var hotKeys: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var pendingCaptureWorkItem: DispatchWorkItem?

    public init() {}

    public func register() throws {
        cancelPendingCapture()
        // 用 userData 携带实例，替代 static weak shared 全局状态（多实例/测试更安全）。
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, event, userData) -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hk
            )
            guard let userData else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                center.handleRegistered(id: hk.id)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &self.handler)

        let prefs = HotKeyPreferences.shared
        let conflicts = prefs.conflictedSlots()
        var failed: Set<HotKeySlot> = []
        var installedLabels: [String] = []

        for slot in HotKeySlot.globalSlots {
            if conflicts.contains(slot) { continue }
            let chord = prefs.chord(for: slot)
            do {
                try install(id: slot.registrationID, key: chord.keyCode, mods: chord.carbonModifiers)
                installedLabels.append("\(slot.title)=\(chord.displayString)")
            } catch {
                failed.insert(slot)
                PinSnapLog.app.error("hotkey register \(slot.rawValue): \(error.localizedDescription)")
            }
        }
        prefs.markRegistrationFailed(failed)
        PinSnapLog.app.info("Hotkeys registered \(installedLabels.joined(separator: " / "))")
    }

    public func unregister() {
        cancelPendingCapture()
        for ref in hotKeys {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeys.removeAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    private func handleRegistered(id: UInt32) {
        guard let slot = HotKeySlot.globalSlots.first(where: { $0.registrationID == id }) else { return }
        switch slot {
        case .capture:
            handleCaptureTap()
        case .paste:
            onAction?(.paste)
        case .hidePins:
            onAction?(.hidePins)
        case .showPins:
            onAction?(.showPins)
        case .delayedCapture:
            onAction?(.delayedCapture)
        case .overlayQuickSave, .overlaySaveAs, .overlayColorCopy, .overlayColorToggle:
            break
        }
    }

    private func handleCaptureTap() {
        if pendingCaptureWorkItem != nil {
            cancelPendingCapture()
            onAction?(.captureLastRegion)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCaptureWorkItem = nil
            self.onAction?(.capture)
        }
        pendingCaptureWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow, execute: work)
    }

    private func cancelPendingCapture() {
        pendingCaptureWorkItem?.cancel()
        pendingCaptureWorkItem = nil
    }

    private func install(id: UInt32, key: UInt32, mods: UInt32) throws {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x504E5350), id: id) // 'PNSP'
        let status = RegisterEventHotKey(key, mods, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            throw CaptureError.failed("热键注册失败 (\(status))")
        }
        hotKeys.append(hotKeyRef)
    }
}

import AppKit
import Carbon
import Foundation

/// 全局热键。默认 F1 截图 / F1 连击上次区域 / F3 贴图 / ⌘H 隐藏 / ⌘⇧H 显示。
@MainActor
public final class HotKeyCenter {
    public enum Action: UInt32 {
        case capture = 1
        case paste = 2
        case hidePins = 3
        case showPins = 4
        case captureLastRegion = 5
    }

    /// F1 单击与连击的判定窗。
    private static let f1DoubleTapWindow: TimeInterval = 0.35

    public var onAction: ((Action) -> Void)?
    private var hotKeys: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var pendingF1WorkItem: DispatchWorkItem?
    private static weak var shared: HotKeyCenter?

    /// 内部注册 id（不直接等于对外 Action；F1 经连击状态机再派发）。
    private enum RegisteredID: UInt32 {
        case f1 = 1
        case f3 = 2
        case hidePins = 3
        case showPins = 4
    }

    public init() {}

    public func register() throws {
        cancelPendingF1()
        HotKeyCenter.shared = self
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, event, _) -> OSStatus in
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
            Task { @MainActor in
                HotKeyCenter.shared?.handleRegistered(id: hk.id)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &self.handler)

        try install(id: RegisteredID.f1.rawValue, key: UInt32(kVK_F1), mods: 0)
        try install(id: RegisteredID.f3.rawValue, key: UInt32(kVK_F3), mods: 0)
        try install(id: RegisteredID.hidePins.rawValue, key: UInt32(kVK_ANSI_H), mods: UInt32(cmdKey))
        try install(id: RegisteredID.showPins.rawValue, key: UInt32(kVK_ANSI_H), mods: UInt32(cmdKey + shiftKey))
        PinSnapLog.app.info("Hotkeys registered F1 / F1×2 / F3 / ⌘H / ⌘⇧H")
    }

    public func unregister() {
        cancelPendingF1()
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
        switch RegisteredID(rawValue: id) {
        case .f1:
            handleF1()
        case .f3:
            onAction?(.paste)
        case .hidePins:
            onAction?(.hidePins)
        case .showPins:
            onAction?(.showPins)
        case .none:
            break
        }
    }

    private func handleF1() {
        if pendingF1WorkItem != nil {
            cancelPendingF1()
            onAction?(.captureLastRegion)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingF1WorkItem = nil
            self.onAction?(.capture)
        }
        pendingF1WorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.f1DoubleTapWindow, execute: work)
    }

    private func cancelPendingF1() {
        pendingF1WorkItem?.cancel()
        pendingF1WorkItem = nil
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

import AppKit
import Carbon
import Foundation

/// 全局热键。默认 ⌃⇧A / ⌃⇧V / ⌃⇧H。
@MainActor
public final class HotKeyCenter {
    public enum Action: UInt32 {
        case capture = 1
        case paste = 2
        case togglePins = 3
    }

    public var onAction: ((Action) -> Void)?
    private var hotKeys: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private static weak var shared: HotKeyCenter?

    public init() {}

    public func register() throws {
        HotKeyCenter.shared = self
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { (_, event, _) -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            Task { @MainActor in
                if let action = Action(rawValue: hk.id) {
                    HotKeyCenter.shared?.onAction?(action)
                }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, &self.handler)

        let mods = UInt32(controlKey + shiftKey)
        try install(id: Action.capture.rawValue, key: UInt32(kVK_ANSI_A), mods: mods)
        try install(id: Action.paste.rawValue, key: UInt32(kVK_ANSI_V), mods: mods)
        try install(id: Action.togglePins.rawValue, key: UInt32(kVK_ANSI_H), mods: mods)
        PinSnapLog.app.info("Hotkeys registered ⌃⇧A/V/H")
    }

    public func unregister() {
        for ref in hotKeys {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeys.removeAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    private func install(id: UInt32, key: UInt32, mods: UInt32) throws {
        var hotKeyRef: EventHotKeyRef?
        var hotKeyID = EventHotKeyID(signature: OSType(0x504E5350), id: id) // 'PNSP'
        let status = RegisterEventHotKey(key, mods, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            throw CaptureError.failed("热键注册失败 (\(status))")
        }
        hotKeys.append(hotKeyRef)
    }
}

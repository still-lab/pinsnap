import AppKit
import Carbon
import Foundation

/// 可持久化的按键组合（Carbon keyCode + modifiers）。
public struct KeyChord: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    /// Carbon: `cmdKey` / `shiftKey` / `optionKey` / `controlKey`
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32 = 0) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    public init(event: NSEvent) {
        self.keyCode = UInt32(event.keyCode)
        var mods: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        self.carbonModifiers = mods
    }

    public var displayString: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyLabel(keyCode))
        return parts.joined()
    }

    public func matches(_ event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == keyCode else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        var expected = NSEvent.ModifierFlags()
        if carbonModifiers & UInt32(cmdKey) != 0 { expected.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { expected.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { expected.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { expected.insert(.control) }
        return flags == expected
    }

    /// 修饰键 alone 不算有效 chord。
    public var isValidBinding: Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_Shift, kVK_Option, kVK_Control,
             kVK_RightCommand, kVK_RightShift, kVK_RightOption, kVK_RightControl:
            return false
        default:
            return true
        }
    }

    private static func keyLabel(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Space: return "Space"
        case kVK_Tab: return "Tab"
        case kVK_Return: return "↩"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_DownArrow: return "↓"
        case kVK_UpArrow: return "↑"
        default:
            break
        }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return String(format: "0x%02X", code)
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return String(format: "0x%02X", code)
            }
            var keysDown: UInt32 = 0
            var chars: [UniChar] = [0, 0, 0, 0]
            var length: Int = 0
            let status = UCKeyTranslate(
                layout,
                UInt16(code),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &keysDown,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else {
                return String(format: "0x%02X", code)
            }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

/// 可改绑槽位（不含「上次区域」——跟随截图键连击）。
public enum HotKeySlot: String, CaseIterable, Codable, Sendable, Identifiable {
    case capture
    case delayedCapture
    case paste
    case hidePins
    case showPins
    case overlayQuickSave
    case overlaySaveAs
    case overlayColorCopy
    case overlayColorToggle

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .capture: return "截图"
        case .delayedCapture: return "延时截图"
        case .paste: return "贴图"
        case .hidePins: return "隐藏贴图"
        case .showPins: return "显示贴图"
        case .overlayQuickSave: return "快捷保存"
        case .overlaySaveAs: return "另存为"
        case .overlayColorCopy: return "取色复制"
        case .overlayColorToggle: return "取色切换"
        }
    }

    public var isGlobal: Bool {
        switch self {
        case .capture, .delayedCapture, .paste, .hidePins, .showPins: return true
        case .overlayQuickSave, .overlaySaveAs, .overlayColorCopy, .overlayColorToggle: return false
        }
    }

    /// Carbon 注册 id（与 Action 解耦；截图键走连击状态机）。
    public var registrationID: UInt32 {
        switch self {
        case .capture: return 1
        case .paste: return 2
        case .hidePins: return 3
        case .showPins: return 4
        case .delayedCapture: return 5
        case .overlayQuickSave, .overlaySaveAs, .overlayColorCopy, .overlayColorToggle: return 0
        }
    }

    public static var globalSlots: [HotKeySlot] {
        allCases.filter(\.isGlobal)
    }

    public static var overlaySlots: [HotKeySlot] {
        allCases.filter { !$0.isGlobal }
    }
}

/// 全局 / Overlay 快捷键偏好。
@MainActor
public final class HotKeyPreferences: ObservableObject {
    public static let shared = HotKeyPreferences()
    public static let didChangeNotification = Notification.Name("pinsnap.hotKeysDidChange")
    private static let storageKey = "pinsnap.hotKeyBindings"

    @Published public private(set) var bindings: [HotKeySlot: KeyChord]
    /// Carbon 注册失败的全局槽位。
    @Published public private(set) var registrationFailed: Set<HotKeySlot> = []

    public static let defaults: [HotKeySlot: KeyChord] = [
        .capture: KeyChord(keyCode: UInt32(kVK_F1)),
        .delayedCapture: KeyChord(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(cmdKey)),
        .paste: KeyChord(keyCode: UInt32(kVK_F3)),
        .hidePins: KeyChord(keyCode: UInt32(kVK_ANSI_H), carbonModifiers: UInt32(cmdKey)),
        .showPins: KeyChord(keyCode: UInt32(kVK_ANSI_H), carbonModifiers: UInt32(cmdKey + shiftKey)),
        .overlayQuickSave: KeyChord(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(cmdKey)),
        .overlaySaveAs: KeyChord(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(cmdKey + shiftKey)),
        .overlayColorCopy: KeyChord(keyCode: UInt32(kVK_ANSI_C)),
        .overlayColorToggle: KeyChord(keyCode: UInt32(kVK_Tab)),
    ]

    private init() {
        bindings = Self.load() ?? Self.defaults
    }

    public func chord(for slot: HotKeySlot) -> KeyChord {
        bindings[slot] ?? Self.defaults[slot]!
    }

    public func displayString(for slot: HotKeySlot) -> String {
        chord(for: slot).displayString
    }

    /// 上次区域：当前截图键×2。
    public var lastRegionDisplayString: String {
        "\(displayString(for: .capture))×2"
    }

    public func setChord(_ chord: KeyChord, for slot: HotKeySlot) {
        guard chord.isValidBinding else { return }
        var next = bindings
        next[slot] = chord
        bindings = next
        persist()
        notify()
    }

    public func resetToDefaults() {
        bindings = Self.defaults
        registrationFailed = []
        persist()
        notify()
    }

    public func markRegistrationFailed(_ failed: Set<HotKeySlot>) {
        registrationFailed = failed
    }

    /// App 内互相冲突的槽位（同 chord）。
    public func conflictedSlots() -> Set<HotKeySlot> {
        var seen: [KeyChord: HotKeySlot] = [:]
        var conflicts: Set<HotKeySlot> = []
        for slot in HotKeySlot.allCases {
            let c = chord(for: slot)
            if let other = seen[c] {
                conflicts.insert(slot)
                conflicts.insert(other)
            } else {
                seen[c] = slot
            }
        }
        return conflicts
    }

    public func isConflicted(_ slot: HotKeySlot) -> Bool {
        conflictedSlots().contains(slot) || registrationFailed.contains(slot)
    }

    private func persist() {
        let payload = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func load() -> [HotKeySlot: KeyChord]? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let raw = try? JSONDecoder().decode([String: KeyChord].self, from: data)
        else { return nil }
        var result = defaults
        for (key, value) in raw {
            if let slot = HotKeySlot(rawValue: key) {
                result[slot] = value
            }
        }
        return result
    }

    private func notify() {
        objectWillChange.send()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}

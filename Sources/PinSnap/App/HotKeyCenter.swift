import AppKit
import Foundation

/// 全局热键。默认 ⌃⇧A / ⌃⇧V / ⌃⇧H，可在设置中修改。
/// REQ: S-02
@MainActor
public final class HotKeyCenter {
    public struct Binding: Equatable {
        public var capture: KeyboardShortcutSpec
        public var paste: KeyboardShortcutSpec
        public var togglePins: KeyboardShortcutSpec

        public static let `default` = Binding(
            capture: .init(keyCode: 0, modifiers: [.control, .shift]), // A — M0 用真实 KeyCode
            paste: .init(keyCode: 9, modifiers: [.control, .shift]),   // V
            togglePins: .init(keyCode: 4, modifiers: [.control, .shift]) // H
        )
    }

    private weak var coordinator: SessionCoordinator?
    public var binding: Binding = .default

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    public func register() throws {
        // M0: 注册系统热键；冲突时抛错供 UI 提示
    }

    public func unregister() {
        // M0
    }
}

public struct KeyboardShortcutSpec: Equatable, Codable {
    public var keyCode: UInt16
    public var modifiers: Modifiers

    public struct Modifiers: OptionSet, Codable, Equatable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

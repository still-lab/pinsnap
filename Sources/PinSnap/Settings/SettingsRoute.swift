import Foundation

/// SwiftUI Settings 将在 M0 接入 Xcode 的 Settings scene。
/// REQ: S-04
public enum SettingsRoute: String, Sendable {
    case general
    case hotkeys
    case save
    case purchase
    case about
}

import Foundation

/// Pro 能力枚举。REQ: S-10
public enum Feature: String, CaseIterable, Codable, Sendable {
    case pinUnlimited
    case pinGroups
    case pinClickThrough
    case historyReplay
    case delayCapture
    case advancedAnnotate
    case filenameTemplate
}

@MainActor
public protocol FeatureGateProtocol: AnyObject {
    var isPro: Bool { get }
    func isEnabled(_ feature: Feature) -> Bool
}

/// StoreKit 接通前可用 stub；开发期可强制 isPro。
@MainActor
public final class FeatureGate: FeatureGateProtocol {
    public static let shared = FeatureGate()

    /// 开发开关：true 时视为已购 Pro（勿带进 Release）。
    public var debugForcePro = false

    public private(set) var isPro = false

    private init() {}

    public func isEnabled(_ feature: Feature) -> Bool {
        if debugForcePro || isPro { return true }
        switch feature {
        case .pinUnlimited, .pinGroups, .pinClickThrough,
             .historyReplay, .delayCapture, .advancedAnnotate, .filenameTemplate:
            return false
        }
    }

    public func applyEntitlement(isPro: Bool) {
        self.isPro = isPro
    }
}

public enum StoreProductID {
    public static let monthly = "app.pinsnap.pro.monthly"
    public static let yearly = "app.pinsnap.pro.yearly"
    public static let lifetime = "app.pinsnap.pro.lifetime"
}

import Foundation
import StoreKit

public enum Feature: String, CaseIterable, Codable, Sendable {
    case pinUnlimited
    case pinGroups
    case pinClickThrough
    case historyReplay
    case delayCapture
    case advancedAnnotate
    case filenameTemplate
    case ocr
    case translate
}

@MainActor
public protocol FeatureGateProtocol: AnyObject {
    var isPro: Bool { get }
    func isEnabled(_ feature: Feature) -> Bool
}

@MainActor
public final class FeatureGate: FeatureGateProtocol {
    public static let shared = FeatureGate()

    /// 现阶段全开（全部免费，含 Release / trial DMG）；付费落地后再改默认 false。
    /// 单测可临时设为 false 验证 Free 上限。Pro 解锁由 `isPro || debugForcePro` 决定。
    public var debugForcePro = true

    public private(set) var isPro = false

    private init() {}

    /// 现阶段：`isPro || debugForcePro`（默认全开）。
    /// 核心能力（截图/基础标注/复制/保存/≤3 贴图/粘贴）不经 FeatureGate，始终可用。
    public func isEnabled(_ feature: Feature) -> Bool {
        isPro || debugForcePro
    }

    public func applyEntitlement(isPro: Bool) {
        self.isPro = isPro
        PinSnapLog.store.info("isPro=\(isPro)")
    }
}

public enum StoreProductID {
    public static let monthly = "app.pinsnap.pro.monthly"
    public static let yearly = "app.pinsnap.pro.yearly"
    public static let lifetime = "app.pinsnap.pro.lifetime"
    public static let all = [monthly, yearly, lifetime]
}

@MainActor
public final class StoreClient {
    public static let shared = StoreClient()
    public private(set) var products: [Product] = []

    private init() {}

    public func refreshEntitlements() async {
        var pro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result {
                if StoreProductID.all.contains(t.productID) {
                    pro = true
                }
            }
        }
        FeatureGate.shared.applyEntitlement(isPro: pro)
    }

    public func loadProducts() async {
        do {
            products = try await Product.products(for: Set(StoreProductID.all))
        } catch {
            PinSnapLog.store.error("products: \(error.localizedDescription)")
        }
    }

    public func purchase(_ product: Product) async throws {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            if case .verified = verification {
                await refreshEntitlements()
            }
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    public func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }
}

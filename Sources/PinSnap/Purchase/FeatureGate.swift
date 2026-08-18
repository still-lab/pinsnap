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

    /// 开发期全开：DEBUG 默认 true（现阶段全免费，便于本地验证）；Release 恒 false。
    /// Pro 能力是否解锁由 `isPro || debugForcePro` 决定。
    #if DEBUG
    public var debugForcePro = true
    #else
    public let debugForcePro = false
    #endif

    public private(set) var isPro = false

    private init() {}

    /// 真门控：Pro 授权或 debugForcePro 解锁全部 Pro 能力；Free 不享任何 Pro 能力。
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

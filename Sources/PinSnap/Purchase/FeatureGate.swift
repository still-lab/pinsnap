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
}

@MainActor
public protocol FeatureGateProtocol: AnyObject {
    var isPro: Bool { get }
    func isEnabled(_ feature: Feature) -> Bool
}

@MainActor
public final class FeatureGate: FeatureGateProtocol {
    public static let shared = FeatureGate()

    #if DEBUG
    public var debugForcePro = false
    #else
    public var debugForcePro = false
    #endif

    public private(set) var isPro = false

    private init() {}

    public func isEnabled(_ feature: Feature) -> Bool {
        if debugForcePro || isPro { return true }
        return false
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

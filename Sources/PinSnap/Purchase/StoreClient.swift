import Foundation

/// StoreKit 2 客户端占位。M3–M4 实现。
/// REQ: S-11, S-12
public protocol StoreClientProtocol: Sendable {
    func refreshEntitlements() async
    func purchase(productID: String) async throws
    func restore() async throws
}

public struct StoreClient: StoreClientProtocol {
    public init() {}

    public func refreshEntitlements() async {
        // M4: Transaction.currentEntitlements → FeatureGate
    }

    public func purchase(productID: String) async throws {
        // M4
    }

    public func restore() async throws {
        // M4
    }
}

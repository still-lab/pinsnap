import CoreGraphics
import Foundation

/// 贴图仓库。Free 上限 3 张（无水印）。
/// REQ: P-01, P-02, P-04, P-09, P-12, P-13
@MainActor
public protocol PinStoreProtocol: AnyObject {
    var pins: [PinItem] { get }
    var freeLimit: Int { get }

    func create(image: CGImage, at frame: CGRect) throws -> PinItem
    func close(id: UUID) throws
    func destroy(id: UUID) throws
    func hideAll()
    func showAll()
    func setClickThrough(id: UUID, enabled: Bool) throws
    func restoreSession() async throws
    func persistSession() async throws
}

@MainActor
public final class PinStore: PinStoreProtocol {
    public let freeLimit = 3
    public private(set) var pins: [PinItem] = []
    private var closedStack: [PinItem] = []
    private var hidden = false
    private let gate: FeatureGateProtocol

    public init(gate: FeatureGateProtocol) {
        self.gate = gate
    }

    public func create(image: CGImage, at frame: CGRect) throws -> PinItem {
        let unlimited = gate.isEnabled(.pinUnlimited)
        if !unlimited, pins.count >= freeLimit {
            throw PinStoreError.freeLimitReached(limit: freeLimit)
        }
        // M2: 写 PNG、创建 NSPanel
        let item = PinItem(frame: frame, imageFileName: "\(UUID().uuidString).png")
        pins.append(item)
        return item
    }

    public func close(id: UUID) throws {
        guard let index = pins.firstIndex(where: { $0.id == id }) else {
            throw PinStoreError.notFound
        }
        let item = pins.remove(at: index)
        closedStack.append(item)
        // 容量策略 M3
    }

    public func destroy(id: UUID) throws {
        pins.removeAll { $0.id == id }
        closedStack.removeAll { $0.id == id }
        // M3: 删文件
    }

    public func hideAll() { hidden = true }
    public func showAll() { hidden = false }

    public func setClickThrough(id: UUID, enabled: Bool) throws {
        guard gate.isEnabled(.pinClickThrough) else {
            throw PinStoreError.featureLocked(.pinClickThrough)
        }
        guard let index = pins.firstIndex(where: { $0.id == id }) else {
            throw PinStoreError.notFound
        }
        pins[index].ignoresMouse = enabled
    }

    public func restoreSession() async throws {
        // M3
    }

    public func persistSession() async throws {
        // M3
    }
}

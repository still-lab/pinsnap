import CoreGraphics
import Foundation

public struct PinGroup: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct PinItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var groupID: UUID?
    public var frame: CGRect
    public var alpha: CGFloat
    public var rotationDegrees: CGFloat
    public var scale: CGFloat
    public var ignoresMouse: Bool
    public var imageFileName: String

    public init(
        id: UUID = UUID(),
        groupID: UUID? = nil,
        frame: CGRect,
        alpha: CGFloat = 1,
        rotationDegrees: CGFloat = 0,
        scale: CGFloat = 1,
        ignoresMouse: Bool = false,
        imageFileName: String
    ) {
        self.id = id
        self.groupID = groupID
        self.frame = frame
        self.alpha = alpha
        self.rotationDegrees = rotationDegrees
        self.scale = scale
        self.ignoresMouse = ignoresMouse
        self.imageFileName = imageFileName
    }
}

public struct PinSessionSnapshot: Codable, Sendable {
    public var version: Int
    public var pins: [PinItem]
    public var groups: [PinGroup]
    public var activeGroupID: UUID?

    public init(
        version: Int = 1,
        pins: [PinItem] = [],
        groups: [PinGroup] = [],
        activeGroupID: UUID? = nil
    ) {
        self.version = version
        self.pins = pins
        self.groups = groups
        self.activeGroupID = activeGroupID
    }
}

public enum PinStoreError: Error, LocalizedError, Sendable {
    case freeLimitReached(limit: Int)
    case notFound
    case featureLocked(Feature)

    public var errorDescription: String? {
        switch self {
        case .freeLimitReached(let limit):
            return "免费版同时最多 \(limit) 张贴图，升级 Pro 解锁无限贴图"
        case .notFound:
            return "贴图不存在"
        case .featureLocked(let feature):
            return "需要 Pro：\(feature.rawValue)"
        }
    }
}

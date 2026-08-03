import AppKit
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
    public var isHidden: Bool

    public init(
        id: UUID = UUID(),
        groupID: UUID? = nil,
        frame: CGRect,
        alpha: CGFloat = 1,
        rotationDegrees: CGFloat = 0,
        scale: CGFloat = 1,
        ignoresMouse: Bool = false,
        imageFileName: String,
        isHidden: Bool = false
    ) {
        self.id = id
        self.groupID = groupID
        self.frame = frame
        self.alpha = alpha
        self.rotationDegrees = rotationDegrees
        self.scale = scale
        self.ignoresMouse = ignoresMouse
        self.imageFileName = imageFileName
        self.isHidden = isHidden
    }
}

public struct PinSessionSnapshot: Codable, Sendable {
    public var version: Int
    public var pins: [PinItem]
    public var groups: [PinGroup]
    public var activeGroupID: UUID?

    public init(version: Int = 1, pins: [PinItem] = [], groups: [PinGroup] = [], activeGroupID: UUID? = nil) {
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
        case .notFound: return "贴图不存在"
        case .featureLocked(let feature): return "需要 Pro：\(feature.rawValue)"
        }
    }
}

@MainActor
public protocol PinStoreProtocol: AnyObject {
    var pins: [PinItem] { get }
    var freeLimit: Int { get }
    func create(image: CGImage, at frame: CGRect?) throws -> PinItem
    func close(id: UUID) throws
    func destroy(id: UUID) throws
    func hideAll()
    func showAll()
    func toggleVisibility()
    func setClickThrough(id: UUID, enabled: Bool) throws
    func clearAllClickThrough()
    func restoreSession() async throws
    func persistSession() async throws
}

@MainActor
public final class PinStore: PinStoreProtocol {
    public let freeLimit = 3
    public private(set) var pins: [PinItem] = []
    private var closedStack: [PinItem] = []
    private var panels: [UUID: PinPanelController] = [:]
    private var allHidden = false
    private let gate: FeatureGateProtocol
    private let sessionDir: URL

    public init(gate: FeatureGateProtocol, sessionDir: URL? = nil) {
        self.gate = gate
        if let sessionDir {
            self.sessionDir = sessionDir
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.sessionDir = base.appendingPathComponent("PinSnap/session", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.sessionDir, withIntermediateDirectories: true)
    }

    public func create(image: CGImage, at frame: CGRect? = nil) throws -> PinItem {
        let unlimited = gate.isEnabled(.pinUnlimited)
        if !unlimited, pins.filter({ !$0.isHidden }).count >= freeLimit {
            throw PinStoreError.freeLimitReached(limit: freeLimit)
        }
        let id = UUID()
        let file = "\(id.uuidString).png"
        let url = sessionDir.appendingPathComponent(file)
        try ImageExporter().save(image, to: url, format: .png)
        let size = NSSize(width: CGFloat(image.width) / (NSScreen.main?.backingScaleFactor ?? 2),
                          height: CGFloat(image.height) / (NSScreen.main?.backingScaleFactor ?? 2))
        let origin = frame?.origin ?? NSPoint(
            x: (NSScreen.main?.frame.midX ?? 400) - size.width / 2,
            y: (NSScreen.main?.frame.midY ?? 300) - size.height / 2
        )
        let item = PinItem(id: id, frame: CGRect(origin: origin, size: size), imageFileName: file)
        pins.append(item)
        let panel = PinPanelController(item: item, imageURL: url, store: self)
        panels[id] = panel
        panel.show()
        Task { try? await persistSession() }
        return item
    }

    public func close(id: UUID) throws {
        guard let index = pins.firstIndex(where: { $0.id == id }) else { throw PinStoreError.notFound }
        let item = pins.remove(at: index)
        panels[id]?.close()
        panels[id] = nil
        closedStack.append(item)
        if closedStack.count > 5 { closedStack.removeFirst() }
        Task { try? await persistSession() }
    }

    public func destroy(id: UUID) throws {
        pins.removeAll { $0.id == id }
        closedStack.removeAll { $0.id == id }
        panels[id]?.close()
        panels[id] = nil
        let url = sessionDir.appendingPathComponent(id.uuidString + ".png")
        try? FileManager.default.removeItem(at: url)
        Task { try? await persistSession() }
    }

    public func hideAll() {
        allHidden = true
        for p in panels.values { p.setVisible(false) }
    }

    public func showAll() {
        allHidden = false
        for p in panels.values { p.setVisible(true) }
    }

    public func toggleVisibility() {
        if allHidden { showAll() } else { hideAll() }
    }

    public func setClickThrough(id: UUID, enabled: Bool) throws {
        guard gate.isEnabled(.pinClickThrough) else { throw PinStoreError.featureLocked(.pinClickThrough) }
        guard let index = pins.firstIndex(where: { $0.id == id }) else { throw PinStoreError.notFound }
        pins[index].ignoresMouse = enabled
        panels[id]?.setClickThrough(enabled)
    }

    public func clearAllClickThrough() {
        for i in pins.indices {
            pins[i].ignoresMouse = false
            panels[pins[i].id]?.setClickThrough(false)
        }
    }

    public func restoreFromClosedIfNeeded() {
        guard let item = closedStack.popLast() else { return }
        let url = sessionDir.appendingPathComponent(item.imageFileName)
        guard let data = try? Data(contentsOf: url),
              let img = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        _ = try? create(image: img, at: item.frame)
    }

    public func restoreSession() async throws {
        let meta = sessionDir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: meta),
              let snap = try? JSONDecoder().decode(PinSessionSnapshot.self, from: data)
        else { return }
        for item in snap.pins {
            let url = sessionDir.appendingPathComponent(item.imageFileName)
            guard let imgData = try? Data(contentsOf: url),
                  NSImage(data: imgData)?.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil
            else { continue }
            if !gate.isEnabled(.pinUnlimited), pins.count >= freeLimit { break }
            let copy = item
            pins.append(copy)
            let panel = PinPanelController(item: copy, imageURL: url, store: self)
            panels[copy.id] = panel
            panel.show()
        }
    }

    public func persistSession() async throws {
        let snap = PinSessionSnapshot(pins: pins, groups: [])
        let data = try JSONEncoder().encode(snap)
        try AtomicFile.write(data, to: sessionDir.appendingPathComponent("meta.json"))
    }

    func panelDidClose(id: UUID) {
        try? close(id: id)
    }
}

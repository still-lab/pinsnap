import AppKit
import CoreGraphics
import XCTest
@testable import PinSnapKit

/// PinStore 生命周期：create / close / destroy / restore / free 上限。REQ: PIN_LIFECYCLE
@MainActor
final class PinStoreLifecycleTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinsnap-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        FeatureGate.shared.debugForcePro = false
        FeatureGate.shared.applyEntitlement(isPro: false)
    }

    override func tearDownWithError() throws {
        FeatureGate.shared.debugForcePro = true
        FeatureGate.shared.applyEntitlement(isPro: false)
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeStore() -> PinStore {
        PinStore(gate: FeatureGate.shared, sessionDir: tempDir)
    }

    func testCreateAddsPinAndWritesFile() async throws {
        let store = makeStore()
        let item = try await store.create(image: Self.makeSolidImage(), at: nil)
        XCTAssertEqual(store.pins.count, 1)
        XCTAssertEqual(store.pins.first?.id, item.id)
        let url = tempDir.appendingPathComponent(item.imageFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testFreeLimitRejectsFourthPin() async throws {
        let store = makeStore()
        let img = Self.makeSolidImage()
        for _ in 0..<3 { _ = try await store.create(image: img, at: nil) }
        XCTAssertEqual(store.pins.count, 3)
        do {
            _ = try await store.create(image: img, at: nil)
            XCTFail("expected freeLimitReached")
        } catch let error as PinStoreError {
            guard case .freeLimitReached(let limit) = error else {
                return XCTFail("expected freeLimitReached, got \(error)")
            }
            XCTAssertEqual(limit, 3)
        } catch {
            XCTFail("expected PinStoreError, got \(error)")
        }
        XCTAssertEqual(store.pins.count, 3)
    }

    func testCloseThenRestoreRecoversPin() async throws {
        let store = makeStore()
        let item = try await store.create(image: Self.makeSolidImage(), at: nil)
        try store.close(id: item.id)
        XCTAssertEqual(store.pins.count, 0)
        await store.restoreFromClosedIfNeeded()
        XCTAssertEqual(store.pins.count, 1)
    }

    func testDestroyRemovesPinAndFile() async throws {
        let store = makeStore()
        let item = try await store.create(image: Self.makeSolidImage(), at: nil)
        let url = tempDir.appendingPathComponent(item.imageFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try store.destroy(id: item.id)
        XCTAssertEqual(store.pins.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDestroyAlsoRemovesFromClosedStack() async throws {
        let store = makeStore()
        let item = try await store.create(image: Self.makeSolidImage(), at: nil)
        try store.close(id: item.id)
        try store.destroy(id: item.id)
        await store.restoreFromClosedIfNeeded()
        XCTAssertEqual(store.pins.count, 0)
    }

    func testRestoreFromEmptyClosedStackIsNoop() async {
        let store = makeStore()
        await store.restoreFromClosedIfNeeded()
        XCTAssertEqual(store.pins.count, 0)
    }

    private static func makeSolidImage(width: Int = 24, height: Int = 24) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}

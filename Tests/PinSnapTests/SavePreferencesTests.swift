import AppKit
import XCTest
@testable import PinSnapKit

/// 保存偏好：格式、文件名模板、唯一文件名。REQ: C-15 / E-02 / E-04
final class SavePreferencesTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SavePreferences.formatKey)
        UserDefaults.standard.removeObject(forKey: SavePreferences.templateKey)
        super.tearDown()
    }

    @MainActor
    func testSaveFormatRoundTrip() {
        SavePreferences.saveFormat = .jpeg
        XCTAssertEqual(SavePreferences.saveFormat, .jpeg)
        SavePreferences.saveFormat = .png
        XCTAssertEqual(SavePreferences.saveFormat, .png)
    }

    @MainActor
    func testSuggestedFileNameRendersTokens() {
        UserDefaults.standard.set("PinSnap-{width}x{height}", forKey: SavePreferences.templateKey)
        let name = SavePreferences.suggestedFileName(width: 100, height: 50, format: .png)
        XCTAssertEqual(name, "PinSnap-100x50.png")
    }

    @MainActor
    func testSuggestedFileNameJPEGExtension() {
        UserDefaults.standard.set("Shot", forKey: SavePreferences.templateKey)
        XCTAssertEqual(SavePreferences.suggestedFileName(width: 10, height: 10, format: .jpeg), "Shot.jpg")
    }

    @MainActor
    func testMakeUniqueFileURLAppendsSuffixOnCollision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinsnap-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        UserDefaults.standard.set("Shot", forKey: SavePreferences.templateKey)
        let first = SavePreferences.makeUniqueFileURL(in: dir, width: 10, height: 10, format: .png)
        try Data([1]).write(to: first)
        let second = SavePreferences.makeUniqueFileURL(in: dir, width: 10, height: 10, format: .png)
        XCTAssertEqual(first.lastPathComponent, "Shot.png")
        XCTAssertEqual(second.lastPathComponent, "Shot-2.png")
    }
}

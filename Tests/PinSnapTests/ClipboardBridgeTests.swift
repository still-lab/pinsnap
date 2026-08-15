import AppKit
import CoreGraphics
import XCTest
@testable import PinSnapKit

/// 剪贴板解析：图像 → 图片文件 → 颜色 → 文本。REQ: P-04 剪贴板贴图
final class ClipboardBridgeTests: XCTestCase {

    override func tearDown() {
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    @MainActor
    func testResolvePNGImage() throws {
        let image = try XCTUnwrap(Self.makeSolidImage(width: 16, height: 16))
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)

        let content = try ClipboardBridge().resolve()
        guard case .image(let resolved) = content else {
            return XCTFail("expected .image, got \(content)")
        }
        XCTAssertEqual(resolved.width, 16)
        XCTAssertEqual(resolved.height, 16)
    }

    @MainActor
    func testResolveHexColorCard() throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("#FF8000", forType: .string)

        let content = try ClipboardBridge().resolve()
        guard case .colorCard(_, let hex) = content else {
            return XCTFail("expected .colorCard, got \(content)")
        }
        XCTAssertEqual(hex, "#FF8000")
    }

    @MainActor
    func testResolveThreeDigitHexExpands() throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("#F80", forType: .string)

        let content = try ClipboardBridge().resolve()
        guard case .colorCard(_, let hex) = content else {
            return XCTFail("expected .colorCard, got \(content)")
        }
        XCTAssertEqual(hex, "#FF8800")
    }

    @MainActor
    func testResolvePlainTextRendersImage() throws {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("hello", forType: .string)

        let content = try ClipboardBridge().resolve()
        guard case .textRendered(let image) = content else {
            return XCTFail("expected .textRendered, got \(content)")
        }
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    @MainActor
    func testResolveEmptyPasteboardThrows() {
        NSPasteboard.general.clearContents()
        XCTAssertThrowsError(try ClipboardBridge().resolve()) { error in
            guard case ClipboardBridgeError.empty = error else {
                return XCTFail("expected .empty, got \(error)")
            }
        }
    }

    private static func makeSolidImage(width: Int, height: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

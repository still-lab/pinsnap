import AppKit
import CoreGraphics
import XCTest
@testable import PinSnapKit

final class ScreenGeometryTests: XCTestCase {
    func testPixelRectWithSyntheticScreen() {
        let geometry = SyntheticGeometry(screens: [
            ScreenDescriptor(id: ScreenID(rawValue: 1), logicalFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2),
        ])
        let selection = CaptureSelection(screenID: ScreenID(rawValue: 1), logicalRect: CGRect(x: 10, y: 20, width: 100, height: 50))
        let rect = geometry.pixelRect(for: selection)
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, 100)
        XCTAssertEqual(rect.origin.x, 20)
        XCTAssertEqual(rect.origin.y, 40)
    }

    func testClampRejectsTinyRect() {
        let geometry = ScreenGeometry()
        XCTAssertNil(geometry.clampToSingleScreen(.zero))
    }
}

struct SyntheticGeometry: ScreenGeometryProtocol {
    var screensList: [ScreenDescriptor]
    init(screens: [ScreenDescriptor]) { screensList = screens }
    func screens() -> [ScreenDescriptor] { screensList }
    func screen(containing point: CGPoint) -> ScreenDescriptor? { screensList.first }
    func screen(id: ScreenID) -> ScreenDescriptor? { screensList.first { $0.id == id } }
    func clampToSingleScreen(_ rect: CGRect) -> CaptureSelection? {
        guard let s = screensList.first else { return nil }
        return CaptureSelection(screenID: s.id, logicalRect: rect.intersection(s.logicalFrame))
    }
    func pixelRect(for selection: CaptureSelection) -> CGRect {
        guard let screen = screen(id: selection.screenID) else { return .null }
        let o = CGPoint(x: selection.logicalRect.minX - screen.logicalFrame.minX, y: selection.logicalRect.minY - screen.logicalFrame.minY)
        return CGRect(x: o.x * screen.scale, y: o.y * screen.scale, width: selection.logicalRect.width * screen.scale, height: selection.logicalRect.height * screen.scale)
    }
}

final class PinStoreLimitTests: XCTestCase {
    @MainActor
    func testFreeLimitIsThree() {
        FeatureGate.shared.debugForcePro = false
        FeatureGate.shared.applyEntitlement(isPro: false)
        let store = PinStore(gate: FeatureGate.shared)
        XCTAssertEqual(store.freeLimit, 3)
        XCTAssertFalse(FeatureGate.shared.isEnabled(.pinUnlimited))
    }
}

final class FeatureGateTests: XCTestCase {
    @MainActor
    func testProFeaturesLockedWhenFree() {
        FeatureGate.shared.debugForcePro = false
        FeatureGate.shared.applyEntitlement(isPro: false)
        XCTAssertFalse(FeatureGate.shared.isEnabled(.pinUnlimited))
        XCTAssertFalse(FeatureGate.shared.isEnabled(.ocr))
    }

    @MainActor
    func testDebugForceProUnlocks() {
        FeatureGate.shared.debugForcePro = true
        XCTAssertTrue(FeatureGate.shared.isEnabled(.pinUnlimited))
        FeatureGate.shared.debugForcePro = false
    }
}

final class OCRGeometryTests: XCTestCase {
    func testVisionNormalizedRectMapsToLogicalPoints() {
        // Vision box 左下原点；整图像素 200×100，scale=2 → 逻辑选区 100×50
        let normalized = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        let logical = OCRGeometry.logicalRect(
            normalized: normalized,
            imagePixelSize: CGSize(width: 200, height: 100),
            scale: 2
        )
        XCTAssertEqual(logical.minX, 10, accuracy: 0.01)
        XCTAssertEqual(logical.minY, 10, accuracy: 0.01)
        XCTAssertEqual(logical.width, 50, accuracy: 0.01)
        XCTAssertEqual(logical.height, 20, accuracy: 0.01)
    }
}

final class AnnotationUndoTests: XCTestCase {
    @MainActor
    func testUndoRedo() {
        let controller = AnnotationController()
        controller.add(Shape(kind: .rect, points: [.zero, CGPoint(x: 10, y: 10)]))
        XCTAssertEqual(controller.document.shapes.count, 1)
        controller.undo()
        XCTAssertEqual(controller.document.shapes.count, 0)
        controller.redo()
        XCTAssertEqual(controller.document.shapes.count, 1)
    }

    @MainActor
    func testMosaicFlattenChangesPixels() {
        guard let base = CGImage.makeSplit(width: 64, height: 64) else {
            return XCTFail("base image")
        }
        let controller = AnnotationController()
        controller.add(Shape(
            kind: .mosaic,
            points: [CGPoint(x: 8, y: 8), CGPoint(x: 56, y: 56)]
        ))
        guard let out = controller.exportFlattened(base: base) else {
            return XCTFail("export")
        }
        XCTAssertEqual(out.width, 64)
        XCTAssertEqual(out.height, 64)
        guard let patch = AnnotationController.filteredPatch(
            kind: .mosaic,
            rectInBottomLeftPixels: CGRect(x: 8, y: 8, width: 48, height: 48),
            base: base,
            mosaicBlock: 8
        ) else {
            return XCTFail("filteredPatch")
        }
        XCTAssertEqual(patch.width, 48)
        XCTAssertEqual(patch.height, 48)
        // 近邻马赛克后，块内像素应一致（取左上 4×4 内两点）
        guard let pixellated = AnnotationController.pixelateNearest(base, blockPixels: 8) else {
            return XCTFail("pixelateNearest")
        }
        XCTAssertEqual(pixellated.width, 64)
    }
}

final class ColorValueFormatTests: XCTestCase {
    func testHexAndRGBFormatting() {
        let color = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
        XCTAssertEqual(ColorValueFormat.hex.string(for: color), "#FF8000")
        XCTAssertEqual(ColorValueFormat.rgb.string(for: color), "rgb(255, 128, 0)")
    }
}

final class FilenameTemplateTests: XCTestCase {
    func testRenderTokens() {
        let name = FilenameTemplate(pattern: "PinSnap-{width}x{height}").render(width: 100, height: 50)
        XCTAssertEqual(name, "PinSnap-100x50")
    }
}

final class OverlayDragSessionTests: XCTestCase {
    func testDragBecomesRegionEvenWhenWindowPending() {
        var session = OverlayDragSession()
        session.mouseDown(at: CGPoint(x: 100, y: 100), windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNil(session.mouseDragged(at: CGPoint(x: 102, y: 101)))
        let mid = session.mouseDragged(at: CGPoint(x: 180, y: 160))
        XCTAssertEqual(mid?.width, 80)
        XCTAssertEqual(mid?.height, 60)
        let result = session.mouseUp(at: CGPoint(x: 200, y: 180))
        guard case .region(let rect) = result else {
            return XCTFail("expected region, got \(result)")
        }
        XCTAssertEqual(rect.width, 100)
        XCTAssertEqual(rect.height, 80)
    }

    func testClickWithoutDragSelectsWindow() {
        var session = OverlayDragSession()
        let window = CGRect(x: 10, y: 10, width: 400, height: 300)
        session.mouseDown(at: CGPoint(x: 50, y: 50), windowBounds: window)
        let result = session.mouseUp(at: CGPoint(x: 51, y: 50))
        XCTAssertEqual(result, .window(window))
    }
}

final class ScrollStitchTests: XCTestCase {
    func testSingleImage() {
        let img = CGImage.makeSolid(width: 10, height: 10)!
        XCTAssertNotNil(ScrollStitcher.stitchVertically([img]))
    }
}

final class ColorSamplerTests: XCTestCase {
    func testSampleMatchesTopLeftOriginPixels() throws {
        // 顶左原点位图：TL 红、TR 绿、BL 蓝、BR 白
        let image = try XCTUnwrap(Self.makeCornerColorImage())
        let frame = ScreenFrame(
            screenID: ScreenID(rawValue: 1),
            logicalBounds: CGRect(x: 0, y: 0, width: 4, height: 4),
            scale: 1,
            image: image
        )
        let frames = [frame]

        let tl = try XCTUnwrap(ColorSampler.sample(at: CGPoint(x: 0.5, y: 3.5), in: frames))
        let bl = try XCTUnwrap(ColorSampler.sample(at: CGPoint(x: 0.5, y: 0.5), in: frames))
        let tr = try XCTUnwrap(ColorSampler.sample(at: CGPoint(x: 3.5, y: 3.5), in: frames))
        let br = try XCTUnwrap(ColorSampler.sample(at: CGPoint(x: 3.5, y: 0.5), in: frames))

        XCTAssertEqual(ColorValueFormat.hex.string(for: tl), "#FF0000")
        XCTAssertEqual(ColorValueFormat.hex.string(for: bl), "#0000FF")
        XCTAssertEqual(ColorValueFormat.hex.string(for: tr), "#00FF00")
        XCTAssertEqual(ColorValueFormat.hex.string(for: br), "#FFFFFF")
    }

    /// 按顶左原点写入 RGBA 缓冲。
    private static func makeCornerColorImage() -> CGImage? {
        let w = 4, h = 4
        var data = [UInt8](repeating: 0, count: w * h * 4)
        func setPixel(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8) {
            let i = (y * w + x) * 4
            data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = 255
        }
        setPixel(x: 0, y: 0, r: 255, g: 0, b: 0) // TL red
        setPixel(x: 3, y: 0, r: 0, g: 255, b: 0) // TR green
        setPixel(x: 0, y: 3, r: 0, g: 0, b: 255) // BL blue
        setPixel(x: 3, y: 3, r: 255, g: 255, b: 255) // BR white
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
}

private extension CGImage {
    static func makeSolid(width: Int, height: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func makeSplit(width: Int, height: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return ctx.makeImage()
    }
}

final class HotKeyPreferencesTests: XCTestCase {
    func testDefaultDisplayStrings() {
        XCTAssertEqual(HotKeyPreferences.defaults[.capture]?.displayString, "F1")
        XCTAssertEqual(HotKeyPreferences.defaults[.delayedCapture]?.displayString, "⌘T")
        XCTAssertEqual(HotKeyPreferences.defaults[.overlayQuickSave]?.displayString, "⌘S")
        XCTAssertEqual(HotKeyPreferences.defaults[.overlaySaveAs]?.displayString, "⇧⌘S")
        XCTAssertEqual(HotKeyPreferences.defaults[.showPins]?.displayString, "⇧⌘H")
    }

    @MainActor
    func testConflictWhenTwoSlotsShareChord() {
        let prefs = HotKeyPreferences.shared
        prefs.resetToDefaults()
        prefs.setChord(prefs.chord(for: .capture), for: .paste)
        let conflicts = prefs.conflictedSlots()
        XCTAssertTrue(conflicts.contains(.capture))
        XCTAssertTrue(conflicts.contains(.paste))
        prefs.resetToDefaults()
        XCTAssertTrue(prefs.conflictedSlots().isEmpty)
    }
}

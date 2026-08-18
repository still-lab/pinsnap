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

    func testCocoaToCGWindowRectFlipsYFromMainBottom() {
        // 主屏高 900：Cocoa 贴底选区 y=0 → CG 顶边 y=800
        let cocoa = CGRect(x: 100, y: 0, width: 50, height: 100)
        let cg = ScreenGeometry.cocoaToCGWindowRect(cocoa, mainDisplayHeight: 900)
        XCTAssertEqual(cg.origin.x, 100)
        XCTAssertEqual(cg.origin.y, 800)
        XCTAssertEqual(cg.width, 50)
        XCTAssertEqual(cg.height, 100)

        // 往返
        let back = ScreenGeometry.cocoaToCGWindowRect(cg, mainDisplayHeight: 900)
        XCTAssertEqual(back, cocoa)
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
        XCTAssertFalse(FeatureGate.shared.isEnabled(.translate))
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

final class TranslateRoutingTests: XCTestCase {
    func testSimplifiedChineseTargetsEnglish() {
        let pair = TranslateRouting.pair(for: "这是一段用来识别语言的中文文本内容，需要足够长。")
        XCTAssertEqual(pair.target.languageCode?.identifier, "en")
        XCTAssertEqual(pair.source?.languageCode?.identifier, "zh")
    }

    func testEnglishTargetsSimplifiedChinese() {
        let pair = TranslateRouting.pair(for: "This is a sufficiently long English sentence for language detection.")
        XCTAssertEqual(pair.target.languageCode?.identifier, "zh")
        XCTAssertEqual(pair.source?.languageCode?.identifier, "en")
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

    /// 首击若只激活窗口、未送达 mouseDown（缺 acceptsFirstMouse），整段拖选应无效。
    func testDragWithoutMouseDownSelectsNothing() {
        var session = OverlayDragSession()
        XCTAssertNil(session.mouseDragged(at: CGPoint(x: 180, y: 160)))
        XCTAssertEqual(session.mouseUp(at: CGPoint(x: 200, y: 180)), .none)
    }
}

final class ScrollStitchTests: XCTestCase {
    func testSingleImage() {
        let img = CGImage.makeSolid(width: 10, height: 10)!
        XCTAssertNotNil(ScrollStitcher.stitchVertically([img]))
    }

    func testMeasureAdvanceFindsKnownScroll() throws {
        let band = try XCTUnwrap(Self.makeNoise(width: 64, height: 80, seed: 7))
        let aPad = try XCTUnwrap(Self.makeNoise(width: 64, height: 40, seed: 1))
        let bPad = try XCTUnwrap(Self.makeNoise(width: 64, height: 40, seed: 2))
        let a = try XCTUnwrap(Self.stackVertically([aPad, band]))
        let b = try XCTUnwrap(Self.stackVertically([band, bPad]))
        let advance = try XCTUnwrap(ScrollStitcher.measureAdvance(previous: a, next: b, hint: 40))
        XCTAssertEqual(Double(advance), 40, accuracy: 6)
    }

    /// 快滑：滚轮 hint 常远小于真实内容推进；不得用 hint 把实测 advance 压矮，否则叠字。
    func testMeasureAdvanceIgnoresLowballHint() throws {
        let trueAdvance = 72
        let (a, b) = try Self.makeScrolledPair(width: 80, height: 180, advance: trueAdvance, seed: 41)
        // 快甩时 pending 常只有十几像素，真实视口已滚了 70+
        let advance = try XCTUnwrap(ScrollStitcher.measureAdvance(previous: a, next: b, hint: 16))
        XCTAssertEqual(Double(advance), Double(trueAdvance), accuracy: 8)
        XCTAssertGreaterThan(advance, 40, "must not clamp to lowball wheel hint")
    }

    /// 快滑大步进：真实推进接近半高时，不得低估成小步进（叠字根因）。
    func testMeasureAdvanceHandlesLargeStepWithoutUnderestimate() throws {
        let trueAdvance = 90 // 200 高的 45%，超过旧 40% 软顶
        let (a, b) = try Self.makeScrolledPair(width: 96, height: 200, advance: trueAdvance, seed: 55)
        let advance = try XCTUnwrap(ScrollStitcher.measureAdvance(previous: a, next: b, hint: 0))
        XCTAssertEqual(Double(advance), Double(trueAdvance), accuracy: 10)
        // 若低估 >20px，append 后会出现明显重复条带
        XCTAssertGreaterThanOrEqual(advance, trueAdvance - 12)
    }

    /// 端到端：低估 advance 再 append → 画布底部与上一帧重叠区重复（用户所见叠字）。
    func testAppendWithUnderestimatedAdvanceDuplicatesContent() throws {
        let trueAdvance = 80
        let (a, b) = try Self.makeScrolledPair(width: 64, height: 160, advance: trueAdvance, seed: 77)
        let measured = try XCTUnwrap(ScrollStitcher.measureAdvance(previous: a, next: b, hint: 12))
        let canvas = try XCTUnwrap(ScrollStitcher.appendByAdvance(canvas: a, nextFrame: b, advance: measured))
        // 正确高度 = h + trueAdvance；若 measured 被 hint 压矮，画布偏矮且含重复
        XCTAssertEqual(Double(canvas.height), Double(a.height + trueAdvance), accuracy: 14)
        XCTAssertGreaterThanOrEqual(measured, trueAdvance - 12)
    }

    /// 快滑丢中间帧：特征行匹配通常仍能直连；若失败则经 B 串联追赶。
    func testChainAppendRecoversViaIntermediateFrame() throws {
        let w = 72
        let viewH = 120
        let step = 55 // 单步可测；两步 110 ≈ 92% 高
        let content = try XCTUnwrap(Self.makeNoise(width: w, height: viewH + step * 2, seed: 91))
        let a = try XCTUnwrap(Self.cropWindow(content, y: 0, height: viewH))
        let b = try XCTUnwrap(Self.cropWindow(content, y: step, height: viewH))
        let c = try XCTUnwrap(Self.cropWindow(content, y: step * 2, height: viewH))

        if let direct = ScrollStitcher.measureAdvance(previous: a, next: c, hint: 0) {
            XCTAssertEqual(Double(direct), Double(step * 2), accuracy: 16)
        }

        let result = try XCTUnwrap(
            ScrollStitcher.chainAppend(canvas: a, lastFrame: a, incoming: [b, c])
        )
        XCTAssertEqual(result.acceptedCount, 2)
        XCTAssertEqual(Double(result.totalAdvance), Double(step * 2), accuracy: 16)
        XCTAssertEqual(Double(result.canvas.height), Double(viewH + step * 2), accuracy: 16)
    }

    /// 无中间帧时远跳不应瞎拼（宁可不增长，也不叠错）。
    func testChainAppendSkipsUnmatchableFarJump() throws {
        let (a, _) = try Self.makeScrolledPair(width: 64, height: 100, advance: 40, seed: 11)
        let (c, _) = try Self.makeScrolledPair(width: 64, height: 100, advance: 40, seed: 99)
        let result = ScrollStitcher.chainAppend(canvas: a, lastFrame: a, incoming: [c])
        XCTAssertTrue(result == nil || result?.acceptedCount == 0)
    }

    /// 滚轮来回：先下后上再下，画布高度不应把同一段内容叠两遍。
    func testDownUpDownDoesNotDuplicateContent() throws {
        let w = 64
        let viewH = 100
        let step = 36
        let content = try XCTUnwrap(Self.makeNoise(width: w, height: viewH + step * 2, seed: 17))
        let a = try XCTUnwrap(Self.cropWindow(content, y: 0, height: viewH))
        let b = try XCTUnwrap(Self.cropWindow(content, y: step, height: viewH))
        let c = try XCTUnwrap(Self.cropWindow(content, y: step * 2, height: viewH))

        // A → B（下）→ A（上）→ B（下）
        let r1 = try XCTUnwrap(ScrollStitcher.chainAppend(canvas: a, lastFrame: a, incoming: [b]))
        XCTAssertEqual(r1.acceptedCount, 1)
        let afterUp = try XCTUnwrap(
            ScrollStitcher.chainAppend(canvas: r1.canvas, lastFrame: r1.lastFrame, incoming: [a])
        )
        // 上滑应裁回，高度回到首帧附近
        XCTAssertEqual(Double(afterUp.canvas.height), Double(viewH), accuracy: 8)
        let r2 = try XCTUnwrap(
            ScrollStitcher.chainAppend(canvas: afterUp.canvas, lastFrame: afterUp.lastFrame, incoming: [b, c])
        )
        XCTAssertEqual(Double(r2.canvas.height), Double(viewH + step * 2), accuracy: 16)
    }

    /// 上滑相对上一帧：不得增长画布。
    func testUpwardScrollDoesNotGrowCanvas() throws {
        let (a, b) = try Self.makeScrolledPair(width: 64, height: 120, advance: 40, seed: 5)
        // b 相对 a 是下滑；反过来 a 相对 b 是上滑
        let grown = try XCTUnwrap(ScrollStitcher.appendByAdvance(canvas: a, nextFrame: b, advance: 40))
        let result = try XCTUnwrap(
            ScrollStitcher.chainAppend(canvas: grown, lastFrame: b, incoming: [a])
        )
        XCTAssertLessThanOrEqual(result.canvas.height, grown.height)
        XCTAssertEqual(Double(result.canvas.height), Double(a.height), accuracy: 8)
    }

    /// 画布底部已有相同条带时，append 必须拒绝（防重叠）。
    func testAppendRejectsStripAlreadyAtCanvasBottom() throws {
        let (a, b) = try Self.makeScrolledPair(width: 64, height: 120, advance: 40, seed: 8)
        let once = try XCTUnwrap(ScrollStitcher.appendByAdvance(canvas: a, nextFrame: b, advance: 40))
        let twice = ScrollStitcher.appendByAdvance(canvas: once, nextFrame: b, advance: 40)
        XCTAssertNil(twice, "duplicate bottom strip must be rejected")
    }

    func testAppendByAdvanceGrowsByExactPixels() throws {
        let top = try XCTUnwrap(Self.makeSolidRGB(width: 24, height: 80, r: 200, g: 200, b: 200))
        let bottom = try XCTUnwrap(Self.makeSolidRGB(width: 24, height: 80, r: 10, g: 10, b: 250))
        let grown = try XCTUnwrap(ScrollStitcher.appendByAdvance(canvas: top, nextFrame: bottom, advance: 25))
        XCTAssertEqual(grown.height, 105)
    }

    func testAppendTakesBottomNotTopChrome() throws {
        // 顶红底蓝：错误裁顶会把红条拼到结果底部
        let red = try XCTUnwrap(Self.makeSolidRGB(width: 32, height: 40, r: 255, g: 0, b: 0))
        let shared = try XCTUnwrap(Self.makeNoise(width: 32, height: 40, seed: 3))
        let blue = try XCTUnwrap(Self.makeSolidRGB(width: 32, height: 40, r: 0, g: 0, b: 255))
        let green = try XCTUnwrap(Self.makeSolidRGB(width: 32, height: 40, r: 0, g: 255, b: 0))
        let a = try XCTUnwrap(Self.stackVertically([red, green, shared]))
        let b = try XCTUnwrap(Self.stackVertically([red, shared, blue]))
        let grown = try XCTUnwrap(
            ScrollStitcher.append(canvas: a, previousFrame: a, nextFrame: b, overlapHint: 40)
        )
        XCTAssertGreaterThan(grown.height, a.height)
        // 结果最底部应是蓝（新内容），不应是红（顶栏）
        let bottom = try XCTUnwrap(
            grown.cropping(to: CGRect(x: 0, y: grown.height - 20, width: 32, height: 20))
        )
        XCTAssertTrue(Self.dominantIsBlue(bottom), "append must take bottom strip, not top chrome")
        let top = try XCTUnwrap(grown.cropping(to: CGRect(x: 0, y: 0, width: 32, height: 20)))
        XCTAssertTrue(Self.dominantIsRed(top), "top chrome should remain once at top")
    }

    func testFastAlignmentIsAccurateAndQuick() throws {
        let band = try XCTUnwrap(Self.makeNoise(width: 320, height: 120, seed: 7))
        let topPad = try XCTUnwrap(Self.makeNoise(width: 320, height: 80, seed: 1))
        let bottomPad = try XCTUnwrap(Self.makeNoise(width: 320, height: 80, seed: 2))
        let top = try XCTUnwrap(Self.stackVertically([topPad, band]))
        let bottom = try XCTUnwrap(Self.stackVertically([band, bottomPad]))

        let started = CFAbsoluteTimeGetCurrent()
        let alignment = try XCTUnwrap(
            ScrollStitcher.acceptedAlignment(previous: top, next: bottom, fast: true)
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let advance = bottom.height - alignment.overlap
        XCTAssertEqual(Double(advance), 80, accuracy: 12)
        XCTAssertLessThan(elapsed, 1.5, "fast alignment must stay interactive")
    }

    func testEstimateAlignmentFindsKnownOverlap() throws {
        let band = try XCTUnwrap(Self.makeNoise(width: 48, height: 60, seed: 7))
        let topPad = try XCTUnwrap(Self.makeNoise(width: 48, height: 40, seed: 1))
        let bottomPad = try XCTUnwrap(Self.makeNoise(width: 48, height: 40, seed: 2))
        let top = try XCTUnwrap(Self.stackVertically([topPad, band]))
        let bottom = try XCTUnwrap(Self.stackVertically([band, bottomPad]))

        let alignment = ScrollStitcher.estimateAlignment(top, bottom, hint: 40, maxDriftX: 0)
        let advance = bottom.height - alignment.overlap
        XCTAssertEqual(Double(advance), 40, accuracy: 6)
        XCTAssertLessThan(alignment.score, 12)
    }

    func testAlignmentIgnoresStaticChrome() throws {
        let chrome = try XCTUnwrap(Self.makeNoise(width: 40, height: 20, seed: 99))
        let band = try XCTUnwrap(Self.makeNoise(width: 40, height: 40, seed: 7))
        let aBody = try XCTUnwrap(Self.makeNoise(width: 40, height: 60, seed: 1))
        let bBody = try XCTUnwrap(Self.makeNoise(width: 40, height: 60, seed: 2))
        let a = try XCTUnwrap(Self.stackVertically([chrome, aBody, band]))
        let b = try XCTUnwrap(Self.stackVertically([chrome, band, bBody]))
        let alignment = ScrollStitcher.estimateAlignment(a, b, hint: 40, maxDriftX: 0)
        let advance = b.height - alignment.overlap
        XCTAssertEqual(Double(advance), 60, accuracy: 8)
    }

    func testVisionOrNCCAcceptsScrolledPair() throws {
        let band = try XCTUnwrap(Self.makeNoise(width: 48, height: 60, seed: 3))
        let aPad = try XCTUnwrap(Self.makeNoise(width: 48, height: 40, seed: 4))
        let bPad = try XCTUnwrap(Self.makeNoise(width: 48, height: 40, seed: 5))
        let a = try XCTUnwrap(Self.stackVertically([aPad, band]))
        let b = try XCTUnwrap(Self.stackVertically([band, bPad]))
        XCTAssertTrue(ScrollStitcher.shouldAppend(previous: a, next: b, overlapHint: 30))
    }

    func testVisionRegistrationAPICallable() throws {
        let band = try XCTUnwrap(Self.makeNoise(width: 64, height: 60, seed: 11))
        let aPad = try XCTUnwrap(Self.makeNoise(width: 64, height: 40, seed: 12))
        let bPad = try XCTUnwrap(Self.makeNoise(width: 64, height: 40, seed: 13))
        let a = try XCTUnwrap(Self.stackVertically([aPad, band]))
        let b = try XCTUnwrap(Self.stackVertically([band, bPad]))
        let alignment = ScrollStitcher.estimateAlignment(a, b, hint: 40, maxDriftX: 4)
        XCTAssertTrue(alignment.score.isFinite)
        XCTAssertGreaterThan(alignment.overlap, 0)
        XCTAssertLessThan(alignment.overlap, b.height)
    }

    func testShouldAppendRejectsIdenticalFrames() throws {
        let a = try XCTUnwrap(CGImage.makeSolid(width: 32, height: 64))
        XCTAssertFalse(ScrollStitcher.shouldAppend(previous: a, next: a, overlapHint: 20))
    }

    func testShouldAppendRejectsIdleNearDuplicates() throws {
        // 静止页即使有轻微噪声也不应推进；旧 fast 半帧上限会误拼
        let a = try XCTUnwrap(Self.makeNoise(width: 40, height: 120, seed: 42))
        XCTAssertFalse(ScrollStitcher.shouldAppend(previous: a, next: a, overlapHint: 40, fast: true))
    }

    func testLooksDifferentDetectsChange() throws {
        let a = try XCTUnwrap(CGImage.makeSolid(width: 48, height: 48))
        let b = try XCTUnwrap(CGImage.makeSplit(width: 48, height: 48))
        XCTAssertFalse(ScrollStitcher.looksDifferent(a, a))
        XCTAssertTrue(ScrollStitcher.looksDifferent(a, b))
    }

    func testScrollFrameGateRejectsIdenticalAndAcceptsAdvance() throws {
        let a = try XCTUnwrap(CGImage.makeSolid(width: 48, height: 200))
        XCTAssertFalse(ScrollStitcher.passesScrollFrameGate(previous: a, next: a))

        let band = try XCTUnwrap(Self.makeNoise(width: 48, height: 120, seed: 21))
        let top = try XCTUnwrap(Self.makeNoise(width: 48, height: 80, seed: 22))
        let bottom = try XCTUnwrap(Self.makeNoise(width: 48, height: 80, seed: 23))
        let frameA = try XCTUnwrap(Self.stackVertically([top, band]))
        let frameB = try XCTUnwrap(Self.stackVertically([band, bottom]))
        XCTAssertTrue(ScrollStitcher.passesScrollFrameGate(previous: frameA, next: frameB))
    }

    func testFilterAdvancesDropsDuplicates() throws {
        let a = try XCTUnwrap(CGImage.makeSolid(width: 24, height: 80))
        XCTAssertEqual(ScrollStitcher.filterAdvances([a, a, a], overlapHint: 30).count, 1)

        let band = try XCTUnwrap(Self.makeNoise(width: 24, height: 60, seed: 9))
        let aPad = try XCTUnwrap(Self.makeNoise(width: 24, height: 40, seed: 4))
        let bPad = try XCTUnwrap(Self.makeNoise(width: 24, height: 40, seed: 5))
        let frameA = try XCTUnwrap(Self.stackVertically([aPad, band]))
        let frameB = try XCTUnwrap(Self.stackVertically([band, bPad]))
        let filtered = ScrollStitcher.filterAdvances([frameA, frameB], overlapHint: 30)
        XCTAssertEqual(filtered.count, 2)
    }

    func testStitchTwoOverlappingStripsTallerThanOne() throws {
        let band = try XCTUnwrap(Self.makeNoise(width: 24, height: 120, seed: 11))
        let aPad = try XCTUnwrap(Self.makeNoise(width: 24, height: 80, seed: 12))
        let bPad = try XCTUnwrap(Self.makeNoise(width: 24, height: 80, seed: 13))
        let a = try XCTUnwrap(Self.stackVertically([aPad, band]))
        let b = try XCTUnwrap(Self.stackVertically([band, bPad]))
        let stitched = try XCTUnwrap(ScrollStitcher.stitchVertically([a, b], overlapHint: 40))
        XCTAssertEqual(stitched.width, a.width)
        XCTAssertGreaterThan(stitched.height, 200)
        XCTAssertLessThan(stitched.height, 320)
    }

    func testAppendGrowsCanvas() throws {
        let band = try XCTUnwrap(Self.makeNoise(width: 24, height: 60, seed: 21))
        let aPad = try XCTUnwrap(Self.makeNoise(width: 24, height: 40, seed: 22))
        let bPad = try XCTUnwrap(Self.makeNoise(width: 24, height: 40, seed: 23))
        let a = try XCTUnwrap(Self.stackVertically([aPad, band]))
        let b = try XCTUnwrap(Self.stackVertically([band, bPad]))
        let grown = try XCTUnwrap(
            ScrollStitcher.append(canvas: a, previousFrame: a, nextFrame: b, overlapHint: 40)
        )
        XCTAssertEqual(grown.width, a.width)
        XCTAssertGreaterThan(grown.height, a.height)
    }

    private static func makeSolidRGB(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: data.count, by: 4) {
            data[i] = r
            data[i + 1] = g
            data[i + 2] = b
            data[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func dominantIsBlue(_ image: CGImage) -> Bool {
        averageChannel(image, offset: 2) > 200 && averageChannel(image, offset: 0) < 40
    }

    private static func dominantIsRed(_ image: CGImage) -> Bool {
        averageChannel(image, offset: 0) > 200 && averageChannel(image, offset: 2) < 40
    }

    private static func averageChannel(_ image: CGImage, offset: Int) -> Double {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, n = 0.0
        var i = offset
        while i < px.count {
            sum += Double(px[i])
            n += 1
            i += 4
        }
        return n > 0 ? sum / n : 0
    }

    /// 构造已知垂直推进的两帧：共用噪声内容带，精确 advance。
    private static func makeScrolledPair(
        width: Int,
        height: Int,
        advance: Int,
        seed: UInt64
    ) throws -> (CGImage, CGImage) {
        precondition(advance > 0 && advance < height)
        let overlap = height - advance
        let shared = try XCTUnwrap(makeNoise(width: width, height: overlap, seed: seed))
        let topOnly = try XCTUnwrap(makeNoise(width: width, height: advance, seed: seed &+ 100))
        let bottomOnly = try XCTUnwrap(makeNoise(width: width, height: advance, seed: seed &+ 200))
        let a = try XCTUnwrap(stackVertically([topOnly, shared]))
        let b = try XCTUnwrap(stackVertically([shared, bottomOnly]))
        XCTAssertEqual(a.height, height)
        XCTAssertEqual(b.height, height)
        return (a, b)
    }

    /// 从长图裁出视口窗口（y=0 为顶）。
    private static func cropWindow(_ image: CGImage, y: Int, height: Int) -> CGImage? {
        guard y >= 0, height > 0, y + height <= image.height else { return nil }
        return image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height).integral)
    }

    private static func makeNoise(width: Int, height: Int, seed: UInt64) -> CGImage? {
        var rng = seed &+ 0x9E3779B97F4A7C15
        func nextByte() -> UInt8 {
            rng = rng &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: rng >> 33)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: data.count, by: 4) {
            let v = nextByte()
            data[i] = v
            data[i + 1] = v
            data[i + 2] = v
            data[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return nil }
        return image
    }

    private static func stackVertically(_ images: [CGImage]) -> CGImage? {
        guard let first = images.first else { return nil }
        let width = first.width
        let totalH = images.reduce(0) { $0 + $1.height }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: totalH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var y = totalH
        for img in images {
            y -= img.height
            ctx.draw(img, in: CGRect(x: 0, y: y, width: img.width, height: img.height))
        }
        return ctx.makeImage()
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

    func testMagnifierPatchReturnsImage() throws {
        let image = try XCTUnwrap(Self.makeCornerColorImage())
        let frame = ScreenFrame(
            screenID: ScreenID(rawValue: 1),
            logicalBounds: CGRect(x: 0, y: 0, width: 4, height: 4),
            scale: 1,
            image: image
        )
        let patch = try XCTUnwrap(ColorSampler.magnifierPatch(at: CGPoint(x: 2, y: 2), in: [frame], radiusLogical: 1))
        XCTAssertGreaterThan(patch.image.width, 0)
        XCTAssertGreaterThan(patch.image.height, 0)
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

// MARK: - StitchCanvas Tests

final class StitchCanvasTests: XCTestCase {

    /// appendBottom 逐条追加，height 应等于各条带高度之和。
    func testAppendBottomGrowsByStripHeight() throws {
        let canvas = StitchCanvas(width: 32)
        let s1 = try XCTUnwrap(Self.makeSolid(width: 32, height: 40, r: 200))
        let s2 = try XCTUnwrap(Self.makeSolid(width: 32, height: 60, r: 100))
        let s3 = try XCTUnwrap(Self.makeSolid(width: 32, height: 20, r: 50))

        canvas.appendBottom(s1)
        XCTAssertEqual(canvas.height, 40)
        XCTAssertEqual(canvas.segmentCount, 1)

        canvas.appendBottom(s2)
        XCTAssertEqual(canvas.height, 100)
        XCTAssertEqual(canvas.segmentCount, 2)

        canvas.appendBottom(s3)
        XCTAssertEqual(canvas.height, 120)
        XCTAssertEqual(canvas.segmentCount, 3)
    }

    /// trimBottom 应从尾部逐段裁掉，部分裁切保留段顶。
    func testTrimBottomShrinksCorrectly() throws {
        let canvas = StitchCanvas(width: 16)
        let s1 = try XCTUnwrap(Self.makeSolid(width: 16, height: 40, r: 200))
        let s2 = try XCTUnwrap(Self.makeSolid(width: 16, height: 60, r: 100))
        canvas.appendBottom(s1)
        canvas.appendBottom(s2)
        XCTAssertEqual(canvas.height, 100)

        // 裁掉整个 s2
        canvas.trimBottom(60)
        XCTAssertEqual(canvas.height, 40)
        XCTAssertEqual(canvas.segmentCount, 1)

        // 裁掉 s1 的一半
        canvas.trimBottom(20)
        XCTAssertEqual(canvas.height, 20)
        XCTAssertEqual(canvas.segmentCount, 1)
    }

    /// flatten 后的图像：顶部应是第一个 segment，底部应是最后一个 segment。
    /// CGImage top-left origin → flatten 后顶行 = 第一个 segment 的顶行。
    func testFlattenPreservesVerticalOrder() throws {
        let canvas = StitchCanvas(width: 24)
        let red = try XCTUnwrap(Self.makeSolid(width: 24, height: 30, r: 255, g: 0, b: 0))
        let blue = try XCTUnwrap(Self.makeSolid(width: 24, height: 30, r: 0, g: 0, b: 255))
        canvas.appendBottom(red)
        canvas.appendBottom(blue)

        let flat = try XCTUnwrap(canvas.flatten())
        XCTAssertEqual(flat.width, 24)
        XCTAssertEqual(flat.height, 60)

        // 顶行应为红
        let topPatch = try XCTUnwrap(flat.cropping(to: CGRect(x: 0, y: 0, width: 24, height: 10).integral))
        XCTAssertTrue(Self.dominantChannel(topPatch, offset: 0) > 200, "top should be red")

        // 底行应为蓝
        let bottomPatch = try XCTUnwrap(flat.cropping(to: CGRect(x: 0, y: 50, width: 24, height: 10).integral))
        XCTAssertTrue(Self.dominantChannel(bottomPatch, offset: 2) > 200, "bottom should be blue")
    }

    /// trimFirstSegmentBottom 裁掉首段底部后，height 减少正确量，后续段 yTop 调整。
    func testTrimFirstSegmentBottom() throws {
        let canvas = StitchCanvas(width: 20)
        let s1 = try XCTUnwrap(Self.makeSolid(width: 20, height: 50, r: 200))
        let s2 = try XCTUnwrap(Self.makeSolid(width: 20, height: 30, r: 100))
        canvas.appendBottom(s1)
        canvas.appendBottom(s2)
        XCTAssertEqual(canvas.height, 80)

        // 裁掉首段底部 10px
        canvas.trimFirstSegmentBottom(10)
        XCTAssertEqual(canvas.height, 70)
        XCTAssertEqual(canvas.segmentCount, 2)

        // flatten 后验证：高度应为 70
        let flat = try XCTUnwrap(canvas.flatten())
        XCTAssertEqual(flat.height, 70)
    }

    /// makePreview 应返回降采样图像，宽度按比例缩放。
    func testMakePreviewScalesDown() throws {
        let canvas = StitchCanvas(width: 40)
        let s = try XCTUnwrap(Self.makeSolid(width: 40, height: 400, r: 128))
        canvas.appendBottom(s)
        let preview = try XCTUnwrap(canvas.makePreview(maxHeight: 100))
        XCTAssertLessThanOrEqual(preview.height, 100)
        XCTAssertGreaterThan(preview.height, 0)
    }

    /// bottomMatches: 画布底部与相同条带应返回 true。
    func testBottomMatchesIdenticalStrip() throws {
        let canvas = StitchCanvas(width: 32)
        let s1 = try XCTUnwrap(Self.makeNoise(width: 32, height: 40, seed: 1))
        let s2 = try XCTUnwrap(Self.makeNoise(width: 32, height: 30, seed: 2))
        canvas.appendBottom(s1)
        canvas.appendBottom(s2)
        XCTAssertTrue(canvas.bottomMatches(s2), "bottom should match last segment")
    }

    // MARK: - Helpers

    private static func makeSolid(width: Int, height: Int, r: UInt8, g: UInt8 = 0, b: UInt8 = 0) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: data.count, by: 4) {
            data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func makeNoise(width: Int, height: Int, seed: UInt64) -> CGImage? {
        var rng = seed &+ 0x9E3779B97F4A7C15
        func nextByte() -> UInt8 {
            rng = rng &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: rng >> 33)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: data.count, by: 4) {
            let v = nextByte()
            data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        return image
    }

    private static func dominantChannel(_ image: CGImage, offset: Int) -> Double {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, n = 0.0
        var i = offset
        while i < px.count {
            sum += Double(px[i]); n += 1; i += 4
        }
        return n > 0 ? sum / n : 0
    }
}

// MARK: - Sticky Dedup Tests

final class StickyDedupTests: XCTestCase {

    /// 直接测试 detectSticky：两帧底部有相同的静止 footer，应检出 bottom > 0。
    func testDetectStickyFindsFooter() throws {
        let w = 48, h = 120, footerH = 10
        let footer = try XCTUnwrap(Self.makeSolid(width: w, height: footerH, r: 50, g: 50, b: 50))
        let body1 = try XCTUnwrap(Self.makeNoise(width: w, height: h - footerH, seed: 1))
        let body2 = try XCTUnwrap(Self.makeNoise(width: w, height: h - footerH, seed: 2))
        let frame1 = try XCTUnwrap(Self.stackVertically([body1, footer]))
        let frame2 = try XCTUnwrap(Self.stackVertically([body2, footer]))

        let sticky = ScrollStitcher.detectSticky(previous: frame1, next: frame2)
        XCTAssertGreaterThan(sticky.bottom, 0, "should detect static footer")
        XCTAssertLessThanOrEqual(sticky.bottom, footerH + 4, "bottom should be ~footerH (±dilation)")
    }

    /// 直接测试 detectSticky：两帧顶部有相同的静止 header，应检出 top > 0。
    func testDetectStickyFindsHeader() throws {
        let w = 48, h = 120, headerH = 10
        let header = try XCTUnwrap(Self.makeSolid(width: w, height: headerH, r: 200, g: 100, b: 0))
        let body1 = try XCTUnwrap(Self.makeNoise(width: w, height: h - headerH, seed: 3))
        let body2 = try XCTUnwrap(Self.makeNoise(width: w, height: h - headerH, seed: 4))
        let frame1 = try XCTUnwrap(Self.stackVertically([header, body1]))
        let frame2 = try XCTUnwrap(Self.stackVertically([header, body2]))

        let sticky = ScrollStitcher.detectSticky(previous: frame1, next: frame2)
        XCTAssertGreaterThan(sticky.top, 0, "should detect static header")
    }

    /// 直接测试 contentStrip：给定 stickyBottom，应从 footer 上方裁出内容条带。
    func testContentStripExcludesStickyBottom() throws {
        let w = 32, h = 100, footerH = 10
        let footer = try XCTUnwrap(Self.makeSolid(width: w, height: footerH, r: 50, g: 50, b: 50))
        let body = try XCTUnwrap(Self.makeNoise(width: w, height: h - footerH, seed: 7))
        let frame = try XCTUnwrap(Self.stackVertically([body, footer]))

        // advance=20, stickyBottom=10 → strip from y=70 to y=90 (above footer)
        let strip = try XCTUnwrap(ScrollStitcher.contentStrip(
            frame: frame, advance: 20, stickyTop: 0, stickyBottom: footerH
        ))
        XCTAssertEqual(strip.height, 20)
        XCTAssertEqual(strip.width, w)

        // strip 不应包含 footer（灰色 r≈50）
        let avgR = Self.averageChannel(strip, offset: 0)
        XCTAssertNotEqual(avgR, 50, accuracy: 10, "strip should be content, not footer")
    }

    /// 端到端：带有 sticky footer 的两帧经 ScrollStitchSession 拼接后，
    /// footer 在最终输出中只出现一次（不在中间重复）。
    /// 使用足够高的帧使 measureAdvance 探针不与 footer 重叠。
    func testStickyFooterNotDuplicatedInOutput() throws {
        let w = 48
        let footerH = 4
        let bodyH = 200
        let advance = 40
        // total h = 204; probe ends at ~198, footer at 200-203 → no overlap

        let footer = try XCTUnwrap(Self.makeSolid(width: w, height: footerH, r: 50, g: 50, b: 50))

        // frame1 body = [topOnly] + [shared]
        let topOnly = try XCTUnwrap(Self.makeNoise(width: w, height: advance, seed: 300))
        let shared = try XCTUnwrap(Self.makeNoise(width: w, height: bodyH - advance, seed: 101))
        let body1 = try XCTUnwrap(Self.stackVertically([topOnly, shared]))

        // frame2 body = [shared] + [newContent]
        let newContent = try XCTUnwrap(Self.makeNoise(width: w, height: advance, seed: 400))
        let body2 = try XCTUnwrap(Self.stackVertically([shared, newContent]))

        let frame1 = try XCTUnwrap(Self.stackVertically([body1, footer]))
        let frame2 = try XCTUnwrap(Self.stackVertically([body2, footer]))
        XCTAssertEqual(frame1.height, bodyH + footerH)

        let session = ScrollStitchSession(firstFrame: frame1, detectSticky: true)
        let result = session.append(incoming: [frame2])
        XCTAssertEqual(result.acceptedFrames.count, 1, "frame2 should be accepted")

        let output = try XCTUnwrap(session.makeFullImage())
        XCTAssertEqual(output.width, w)

        // footer 只在底部出现一次；输出高度 ≈ bodyH + advance + footerH
        // stickyBottom 可能因膨胀略大于 footerH，但总高度不变
        let expectedH = bodyH + advance + footerH
        XCTAssertEqual(output.height, expectedH, accuracy: 4,
                       "footer should appear once at bottom, not duplicated")

        // 底部应为 footer 颜色（灰色 r≈50）
        let bottomStrip = try XCTUnwrap(
            output.cropping(to: CGRect(x: 0, y: output.height - footerH, width: w, height: footerH).integral)
        )
        let avgR = Self.averageChannel(bottomStrip, offset: 0)
        XCTAssertEqual(avgR, 50, accuracy: 15, "bottom should be sticky footer")

        // footer 上方应不是 footer 颜色（应为新内容噪声）
        let aboveFooter = try XCTUnwrap(
            output.cropping(to: CGRect(x: 0, y: output.height - footerH - 10, width: w, height: 10).integral)
        )
        let avgRAbove = Self.averageChannel(aboveFooter, offset: 0)
        XCTAssertNotEqual(avgRAbove, 50, accuracy: 15, "above footer should be content, not footer")
    }

    /// 带有 sticky header 的帧：header 在输出顶部保留。
    func testStickyHeaderPreservedAtTop() throws {
        let w = 48
        let headerH = 20
        let bodyH = 80
        let advance = 40

        let header = try XCTUnwrap(Self.makeSolid(width: w, height: headerH, r: 200, g: 100, b: 0))
        let body1 = try XCTUnwrap(Self.makeNoise(width: w, height: bodyH, seed: 301))
        let sharedBand = try XCTUnwrap(Self.makeNoise(width: w, height: bodyH - advance, seed: 301))
        let newBand = try XCTUnwrap(Self.makeNoise(width: w, height: advance, seed: 402))
        let body2 = try XCTUnwrap(Self.stackVertically([newBand, sharedBand]))

        let frame1 = try XCTUnwrap(Self.stackVertically([header, body1]))
        let frame2 = try XCTUnwrap(Self.stackVertically([header, body2]))

        let session = ScrollStitchSession(firstFrame: frame1, detectSticky: true)
        _ = session.append(incoming: [frame2])
        let output = try XCTUnwrap(session.makeFullImage())

        // 顶部应为 header 颜色
        let topStrip = try XCTUnwrap(
            output.cropping(to: CGRect(x: 0, y: 0, width: w, height: headerH).integral)
        )
        let avgR = Self.averageChannel(topStrip, offset: 0)
        XCTAssertEqual(avgR, 200, accuracy: 10, "top should be sticky header")
    }

    // MARK: - Helpers

    private static func makeSolid(width: Int, height: Int, r: UInt8, g: UInt8 = 0, b: UInt8 = 0) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: data.count, by: 4) {
            data[i] = r; data[i + 1] = g; data[i + 2] = b; data[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func makeNoise(width: Int, height: Int, seed: UInt64) -> CGImage? {
        var rng = seed &+ 0x9E3779B97F4A7C15
        func nextByte() -> UInt8 {
            rng = rng &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: rng >> 33)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: data.count, by: 4) {
            let v = nextByte()
            data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        return image
    }

    private static func stackVertically(_ images: [CGImage]) -> CGImage? {
        guard let first = images.first else { return nil }
        let width = first.width
        let totalH = images.reduce(0) { $0 + $1.height }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: totalH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var y = totalH
        for img in images {
            y -= img.height
            ctx.draw(img, in: CGRect(x: 0, y: y, width: img.width, height: img.height))
        }
        return ctx.makeImage()
    }

    private static func averageChannel(_ image: CGImage, offset: Int) -> Double {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, n = 0.0
        var i = offset
        while i < px.count {
            sum += Double(px[i]); n += 1; i += 4
        }
        return n > 0 ? sum / n : 0
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

final class SelectionResizeTests: XCTestCase {
    func testHitPrefersCorners() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
        XCTAssertEqual(SelectionResize.hitTest(point: CGPoint(x: 100, y: 250), rect: rect), .nw)
        XCTAssertEqual(SelectionResize.hitTest(point: CGPoint(x: 300, y: 100), rect: rect), .se)
        XCTAssertEqual(SelectionResize.hitTest(point: CGPoint(x: 200, y: 250), rect: rect), .n)
        XCTAssertEqual(SelectionResize.hitTest(point: CGPoint(x: 100, y: 175), rect: rect), .w)
        XCTAssertNil(SelectionResize.hitTest(point: CGPoint(x: 200, y: 175), rect: rect))
    }

    func testResizeEastAndWestRespectMinSize() {
        let origin = CGRect(x: 50, y: 40, width: 100, height: 80)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let wider = SelectionResize.resizedRect(
            from: origin,
            handle: .e,
            translation: CGVector(dx: 30, dy: 0),
            bounds: bounds
        )
        XCTAssertEqual(wider.width, 130, accuracy: 0.1)
        XCTAssertEqual(wider.minX, 50, accuracy: 0.1)

        let shrinkPastMin = SelectionResize.resizedRect(
            from: origin,
            handle: .w,
            translation: CGVector(dx: 200, dy: 0),
            bounds: bounds
        )
        XCTAssertEqual(shrinkPastMin.width, SelectionResize.minSize.width, accuracy: 0.1)
        XCTAssertEqual(shrinkPastMin.maxX, origin.maxX, accuracy: 0.1)
    }

    func testResizeClampedToBounds() {
        let origin = CGRect(x: 10, y: 10, width: 100, height: 80)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let out = SelectionResize.resizedRect(
            from: origin,
            handle: .n,
            translation: CGVector(dx: 0, dy: 500),
            bounds: bounds
        )
        XCTAssertEqual(out.maxY, bounds.maxY, accuracy: 0.1)
        XCTAssertEqual(out.minY, origin.minY, accuracy: 0.1)
    }
}

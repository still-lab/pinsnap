
import XCTest
import CoreGraphics
@testable import PinSnapKit

/// 重叠/叠字诊断：Session.makeFullImage 路径必须不把同一内容条带画两次。
final class OverlapDiagnosisTests: XCTestCase {

    /// 已知推进：唯一色带只应在输出中出现一次。
    func testSessionFullImageDoesNotDuplicateUniqueBand() throws {
        let w = 48
        let viewH = 120
        let advance = 40
        let markerH = 8

        // 长内容：… noise | RED marker | noise …
        let top = try XCTUnwrap(Self.noise(w: w, h: viewH - markerH, seed: 1))
        let marker = try XCTUnwrap(Self.solid(w: w, h: markerH, r: 255, g: 0, b: 0))
        let mid = try XCTUnwrap(Self.noise(w: w, h: advance, seed: 2))
        let bottom = try XCTUnwrap(Self.noise(w: w, h: viewH, seed: 3))
        let content = try XCTUnwrap(Self.stack([top, marker, mid, bottom]))

        let f1 = try XCTUnwrap(Self.crop(content, y: 0, h: viewH))
        let f2 = try XCTUnwrap(Self.crop(content, y: advance, h: viewH))

        let measured = try XCTUnwrap(ScrollStitcher.measureAdvance(previous: f1, next: f2))
        XCTAssertEqual(Double(measured), Double(advance), accuracy: 6,
                       "advance 测错会直接导致叠字: got \(measured)")

        let session = ScrollStitchSession(firstFrame: f1)
        let result = session.append(f2)
        XCTAssertTrue(result.didGrow, "frame2 should append")
        let out = try XCTUnwrap(session.makeFullImage())

        // 输出高度应 ≈ viewH + advance
        XCTAssertEqual(Double(out.height), Double(viewH + advance), accuracy: 8)

        // 红色 marker 行数：理想 = markerH；若叠字会接近 2*markerH
        let redRows = Self.countRedRows(out, minR: 200, maxGB: 40)
        XCTAssertLessThanOrEqual(redRows, markerH + 2,
                                 "marker 出现 \(redRows) 行，疑似整帧重叠绘制导致重复")
        XCTAssertGreaterThanOrEqual(redRows, markerH - 2, "marker 应仍在输出中")
    }

    /// 粘性顶栏：整帧叠绘会在中部再画一遍顶栏 → 典型「重叠」。
    func testStickyHeaderCausesMidCanvasDuplicationWithFullFrameDraw() throws {
        let w = 48
        let headerH = 24
        let bodyH = 100
        let advance = 36

        let header = try XCTUnwrap(Self.solid(w: w, h: headerH, r: 0, g: 0, b: 220)) // blue sticky
        let body1 = try XCTUnwrap(Self.noise(w: w, h: bodyH, seed: 10))
        let shared = try XCTUnwrap(Self.crop(body1, y: advance, h: bodyH - advance))
        let neu = try XCTUnwrap(Self.noise(w: w, h: advance, seed: 11))
        let body2 = try XCTUnwrap(Self.stack([shared, neu]))

        let f1 = try XCTUnwrap(Self.stack([header, body1]))
        let f2 = try XCTUnwrap(Self.stack([header, body2]))

        let measured = ScrollStitcher.measureAdvance(previous: f1, next: f2)
        let session = ScrollStitchSession(firstFrame: f1)
        let result = session.append(f2)
        let out = try XCTUnwrap(session.makeFullImage())

        // 诊断信息
        let bands = Self.blueStickyBands(out, headerH: headerH)
        let msg = "measured=\(String(describing: measured)) didGrow=\(result.didGrow) advance=\(result.totalAdvance) outH=\(out.height) bands@\(bands) frameCount=\(session.frameCount)"
        print("DIAG sticky: \(msg)")

        XCTAssertTrue(result.didGrow, "必须拼上第二帧才能诊断重叠: \(msg)")
        XCTAssertEqual(Double(result.totalAdvance), Double(advance), accuracy: 10, msg)

        // 若走整帧绘制：蓝色顶栏会出现在 y=0 与 y≈advance 两处
        XCTAssertEqual(bands.count, 1,
                       "粘性顶栏出现 \(bands.count) 段（\(msg)）。整帧 drawScrollView 会在中部重复顶栏。")
    }

    /// 连续多帧小步进：若 advance 系统性偏低，输出高度会明显矮于真值（叠字伴随偏矮）。
    func testMultiFrameHeightMatchesSumOfAdvances() throws {
        let w = 64
        let viewH = 100
        let step = 30
        let steps = 5
        let content = try XCTUnwrap(Self.noise(w: w, h: viewH + step * steps, seed: 42))
        var frames: [CGImage] = []
        for i in 0...steps {
            frames.append(try XCTUnwrap(Self.crop(content, y: i * step, h: viewH)))
        }
        let session = ScrollStitchSession(firstFrame: frames[0])
        var sum = 0
        for f in frames.dropFirst() {
            let r = session.append(f)
            XCTAssertTrue(r.didGrow, "step failed at sum=\(sum)")
            sum += r.totalAdvance
        }
        let out = try XCTUnwrap(session.makeFullImage())
        let expected = viewH + step * steps
        print("DIAG multi: sumAdv=\(sum) outH=\(out.height) expected=\(expected) frames=\(session.frameCount)")
        XCTAssertEqual(Double(out.height), Double(expected), accuracy: 20)
        // 相邻帧内容相关：抽查输出不应在相邻 step 窗口高度内出现高相似重复（简化：高度达标即可）
        XCTAssertEqual(Double(sum), Double(step * steps), accuracy: 20)
    }

    // MARK: - Helpers

    private static func noise(w: Int, h: Int, seed: UInt64) -> CGImage? {
        var s = seed == 0 ? 1 : seed
        func next() -> UInt8 {
            s = s &* 6364136223846793005 &+ 1
            return UInt8((s >> 33) & 0xFF)
        }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let o = i * 4
            rgba[o] = next(); rgba[o+1] = next(); rgba[o+2] = next(); rgba[o+3] = 255
        }
        return image(rgba: rgba, w: w, h: h)
    }

    private static func solid(w: Int, h: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let o = i * 4
            rgba[o] = r; rgba[o+1] = g; rgba[o+2] = b; rgba[o+3] = 255
        }
        return image(rgba: rgba, w: w, h: h)
    }

    private static func image(rgba: [UInt8], w: Int, h: Int) -> CGImage? {
        var buf = rgba
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let img = ctx.makeImage() else { return nil }
        return img
    }

    private static func stack(_ images: [CGImage]) -> CGImage? {
        guard let first = images.first else { return nil }
        let w = first.width
        let h = images.reduce(0) { $0 + $1.height }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // CGContext y=0 bottom：从顶往下画
        var yTop = 0
        for img in images {
            let cgY = h - yTop - img.height
            ctx.draw(img, in: CGRect(x: 0, y: cgY, width: w, height: img.height))
            yTop += img.height
        }
        return ctx.makeImage()
    }

    private static func crop(_ image: CGImage, y: Int, h: Int) -> CGImage? {
        image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: h).integral)
    }

    private static func countRedRows(_ image: CGImage, minR: UInt8, maxGB: UInt8) -> Int {
        guard let data = rgba(image) else { return 0 }
        let w = image.width, h = image.height
        var rows = 0
        for y in 0..<h {
            var red = 0
            for x in 0..<w {
                let o = (y * w + x) * 4
                if data[o] >= minR && data[o+1] <= maxGB && data[o+2] <= maxGB { red += 1 }
            }
            if red > w / 2 { rows += 1 }
        }
        return rows
    }

    private static func blueStickyBands(_ image: CGImage, headerH: Int) -> [Int] {
        guard let data = rgba(image) else { return [] }
        let w = image.width, h = image.height
        var isBlue = [Bool](repeating: false, count: h)
        for y in 0..<h {
            var blue = 0
            for x in 0..<w {
                let o = (y * w + x) * 4
                if data[o+2] >= 180 && data[o] <= 60 && data[o+1] <= 60 { blue += 1 }
            }
            isBlue[y] = blue > w / 2
        }
        var bands: [Int] = []
        var y = 0
        while y < h {
            if isBlue[y] {
                let start = y
                while y < h && isBlue[y] { y += 1 }
                if y - start >= headerH / 2 { bands.append(start) }
            } else {
                y += 1
            }
        }
        return bands
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // 与 grayTopLeft 相同：不翻转。注意：默认 CTM 下 draw 后内存行0是否为顶取决于实现；
        // 用裁剪坐标系对照：再读 CGImage 时同样方式即可自洽。
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }
}

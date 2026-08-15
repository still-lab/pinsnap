import CoreGraphics
import XCTest
@testable import PinSnapKit

/// 回归：正文类内容上 measureAdvance 不得系统性估小（叠影根因）。
final class AdvanceBiasRegressionTests: XCTestCase {

    func testArticleLikeAdvanceNotSystematicallyUnderestimated() throws {
        let viewH = 300
        let w = 200
        let content = try XCTUnwrap(Self.makeArticle(w: w, h: 2000))
        var sumBias = 0
        var samples = 0
        var underBy1 = 0
        var underByMany = 0
        for trueAdv in [12, 16, 20, 24, 28, 32, 40, 48, 56, 64] {
            for start in stride(from: 0, to: 900, by: 37) {
                guard start + trueAdv + viewH <= content.height else { continue }
                let a = try XCTUnwrap(content.cropping(to: CGRect(x: 0, y: start, width: w, height: viewH)))
                let b = try XCTUnwrap(content.cropping(to: CGRect(x: 0, y: start + trueAdv, width: w, height: viewH)))
                guard let m = ScrollStitcher.measureAdvance(previous: a, next: b) else { continue }
                let d = m - trueAdv
                sumBias += d
                samples += 1
                if d == -1 { underBy1 += 1 }
                if d <= -8 { underByMany += 1 }
            }
        }
        XCTAssertGreaterThan(samples, 50)
        let mean = Double(sumBias) / Double(samples)
        XCTAssertGreaterThan(mean, -1.5, "meanBias=\(mean) under1=\(underBy1) underMany=\(underByMany) n=\(samples)")
        XCTAssertLessThan(underByMany, samples / 10, "severe under-advance \(underByMany)/\(samples)")
    }

    func testDenseSmallStepsHeightNearTruth() throws {
        let viewH = 200
        let w = 160
        let step = 12
        let steps = 20
        let content = try XCTUnwrap(Self.makeArticle(w: w, h: viewH + step * steps + 40))
        let session = ScrollStitchSession(firstFrame: try XCTUnwrap(
            content.cropping(to: CGRect(x: 0, y: 0, width: w, height: viewH))
        ))
        for i in 1...steps {
            let f = try XCTUnwrap(content.cropping(to: CGRect(x: 0, y: i * step, width: w, height: viewH)))
            _ = session.append(f)
        }
        let out = try XCTUnwrap(session.makeFullImage())
        let expected = viewH + step * steps
        XCTAssertEqual(Double(out.height), Double(expected), accuracy: 40,
                       "outH=\(out.height) expected=\(expected) adv=\(session.totalAdvance)")
    }

    func testNoiseAdvanceStillExact() throws {
        let trueAdvance = 40
        let (a, b) = try Self.makeScrolledNoise(width: 96, height: 180, advance: trueAdvance, seed: 11)
        let measured = try XCTUnwrap(ScrollStitcher.measureAdvance(previous: a, next: b))
        XCTAssertEqual(Double(measured), Double(trueAdvance), accuracy: 4)
    }

    // MARK: - Fixtures

    private static func makeArticle(w: Int, h: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 250, count: w * h * 4)
        for i in 0..<(w * h) { rgba[i * 4 + 3] = 255 }
        var y = 0
        var para = 0
        while y < h {
            let paraH = 80 + (para % 5) * 10
            fill(&rgba, w: w, y0: y, h: 14, v: 30)
            y += 18
            let paraEnd = min(h, y + paraH)
            while y < paraEnd {
                let lineW = w - 20 - (para * 3 + y) % 40
                for x in 10..<min(w - 10, 10 + lineW) {
                    if (x + y * 3) % 5 < 3 {
                        set(&rgba, w: w, x: x, y: y, v: 45)
                        if y + 1 < h { set(&rgba, w: w, x: x, y: y + 1, v: 45) }
                    }
                }
                y += 4
            }
            y += 12
            para += 1
        }
        return img(rgba, w, h)
    }

    private static func makeScrolledNoise(width: Int, height: Int, advance: Int, seed: UInt64) throws -> (CGImage, CGImage) {
        var s = seed == 0 ? 1 : seed
        func next() -> UInt8 {
            s = s &* 6364136223846793005 &+ 1
            return UInt8((s >> 33) & 0xFF)
        }
        var rgba = [UInt8](repeating: 0, count: width * (height + advance) * 4)
        for i in 0..<(width * (height + advance)) {
            let o = i * 4
            rgba[o] = next(); rgba[o + 1] = next(); rgba[o + 2] = next(); rgba[o + 3] = 255
        }
        let content = try XCTUnwrap(img(rgba, width, height + advance))
        let a = try XCTUnwrap(content.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)))
        let b = try XCTUnwrap(content.cropping(to: CGRect(x: 0, y: advance, width: width, height: height)))
        return (a, b)
    }

    private static func fill(_ rgba: inout [UInt8], w: Int, y0: Int, h: Int, v: UInt8) {
        let maxY = rgba.count / (w * 4)
        for y in y0..<min(y0 + h, maxY) {
            for x in 0..<w { set(&rgba, w: w, x: x, y: y, v: v) }
        }
    }

    private static func set(_ rgba: inout [UInt8], w: Int, x: Int, y: Int, v: UInt8) {
        let o = (y * w + x) * 4
        guard o + 3 < rgba.count else { return }
        rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 255
    }

    private static func img(_ rgba: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        var buf = rgba
        let cs = CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
}

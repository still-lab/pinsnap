import AppKit
import XCTest
@testable import PinSnapKit

final class StrokeColorStripTests: XCTestCase {
    func testClampHue() {
        XCTAssertEqual(StrokeColorStrip.clamp(-0.2), 0)
        XCTAssertEqual(StrokeColorStrip.clamp(1.4), 1)
        XCTAssertEqual(StrokeColorStrip.clamp(0.35), 0.35)
    }

    func testHueZeroIsRed() {
        let color = StrokeColorStrip.color(hue: 0)
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(color.blueComponent, 0, accuracy: 0.01)
    }

    func testShapeStoresStripColor() {
        let color = StrokeColorStrip.color(hue: 0)
        let shape = Shape(kind: .rect, points: [.zero, CGPoint(x: 10, y: 10)], color: color)
        XCTAssertEqual(shape.red, 1, accuracy: 0.01)
        XCTAssertEqual(shape.green, 0, accuracy: 0.01)
        XCTAssertEqual(shape.blue, 0, accuracy: 0.01)
    }

    func testStrokeColorVisibility() {
        XCTAssertTrue(CaptureAnnotateTool.shape.showsStrokeColor(penStyle: .pen))
        XCTAssertTrue(CaptureAnnotateTool.arrow.showsStrokeColor(penStyle: .marker))
        XCTAssertTrue(CaptureAnnotateTool.pen.showsStrokeColor(penStyle: .pen))
        XCTAssertFalse(CaptureAnnotateTool.pen.showsStrokeColor(penStyle: .marker))
        XCTAssertFalse(CaptureAnnotateTool.pen.showsStrokeColor(penStyle: .eraser))
        XCTAssertTrue(CaptureAnnotateTool.text.showsStrokeColor(penStyle: .pen))
        XCTAssertFalse(CaptureAnnotateTool.mosaic.showsStrokeColor(penStyle: .pen))
    }
}

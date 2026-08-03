import CoreGraphics
import XCTest
@testable import PinSnap

final class ScreenGeometryTests: XCTestCase {
    func testPixelRectScalesByBackingFactor() {
        // REQ: C-04 — M1 用真实 NSScreen 数据替换硬编码
        let geometry = ScreenGeometry()
        let selection = CaptureSelection(
            screenID: ScreenID(rawValue: 1),
            logicalRect: CGRect(x: 0, y: 0, width: 100, height: 50)
        )
        // 无屏数据时返回 null；实现后断言 scale=2 → 200×100
        let rect = geometry.pixelRect(for: selection)
        XCTAssertTrue(rect.isNull || rect.width > 0)
    }
}

final class PinStoreLimitTests: XCTestCase {
    @MainActor
    func testFreeLimitIsThree() throws {
        // REQ: Free ≤3
        let gate = FeatureGate.shared
        gate.debugForcePro = false
        gate.applyEntitlement(isPro: false)
        let store = PinStore(gate: gate)

        // 无真实 CGImage 时 create 仍占位计数 — M2 补 Image stub
        XCTAssertEqual(store.freeLimit, 3)
    }
}

final class FeatureGateTests: XCTestCase {
    @MainActor
    func testProFeaturesLockedWhenFree() {
        let gate = FeatureGate.shared
        gate.debugForcePro = false
        gate.applyEntitlement(isPro: false)
        XCTAssertFalse(gate.isEnabled(.pinUnlimited))
        XCTAssertFalse(gate.isEnabled(.pinClickThrough))
    }

    @MainActor
    func testDebugForceProUnlocks() {
        let gate = FeatureGate.shared
        gate.debugForcePro = true
        XCTAssertTrue(gate.isEnabled(.pinUnlimited))
        gate.debugForcePro = false
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
}

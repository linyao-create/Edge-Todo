import XCTest
@testable import EdgeTodoApp

final class NativeCaptureToastPlacementTests: XCTestCase {
    func testPlacesToastBelowPointerAndWithinVisibleScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 220, height: 58)
        let frame = NativeCaptureToastPlacement.frame(pointer: CGPoint(x: 1050, y: 850), visibleFrame: visible, size: size)
        XCTAssertEqual(frame.midX, 1050, accuracy: 0.01)
        XCTAssertLessThan(frame.maxY, 850)
        XCTAssertTrue(visible.contains(frame))
        let edge = NativeCaptureToastPlacement.frame(pointer: CGPoint(x: 1438, y: 850), visibleFrame: visible, size: size)
        XCTAssertLessThanOrEqual(edge.maxX, visible.maxX)
        XCTAssertGreaterThanOrEqual(edge.minX, visible.minX)
        let bottom = NativeCaptureToastPlacement.frame(pointer: CGPoint(x: 12, y: 10), visibleFrame: visible, size: size)
        XCTAssertTrue(visible.contains(bottom))
    }
}

import AppKit
import XCTest
@testable import EdgeTodoApp

final class PinnedMaterialTests: XCTestCase {
    func testWindowShadowFollowsMaterialAndExpansion() {
        XCTAssertFalse(PinnedMaterialPolicy.useWindowShadow(isExpanded: false, isPinned: false, reduceTransparency: false))
        XCTAssertFalse(PinnedMaterialPolicy.useWindowShadow(isExpanded: true, isPinned: true, reduceTransparency: false))
        XCTAssertTrue(PinnedMaterialPolicy.useWindowShadow(isExpanded: true, isPinned: false, reduceTransparency: false))
        XCTAssertTrue(PinnedMaterialPolicy.useWindowShadow(isExpanded: true, isPinned: true, reduceTransparency: true))
    }

    func testMaterialIsUsedOnlyForPinnedPanelWhenTransparencyAllowed() {
        XCTAssertFalse(PinnedMaterialPolicy.useMaterial(isPinned: false, reduceTransparency: false))
        XCTAssertFalse(PinnedMaterialPolicy.useMaterial(isPinned: true, reduceTransparency: true))
        XCTAssertTrue(PinnedMaterialPolicy.useMaterial(isPinned: true, reduceTransparency: false))
    }
    @MainActor func testUsesApprovedPopoverAndPassesPointerThrough() {
        let view = PinnedPanelMaterial.makeEffectView()
        XCTAssertEqual(view.material, .popover)
        XCTAssertEqual(view.blendingMode, .behindWindow)
        XCTAssertEqual(view.alphaValue, 0.88, accuracy: 0.001)
        XCTAssertNil(view.hitTest(NSPoint(x: 1, y: 1)))
    }
}

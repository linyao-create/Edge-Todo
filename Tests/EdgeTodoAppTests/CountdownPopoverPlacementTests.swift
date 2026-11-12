import XCTest
@testable import EdgeTodoApp

final class CountdownPopoverPlacementTests: XCTestCase {
    func testNearTopPlacesBelowAndWithinPanel() {
        let frame = CountdownPopoverPlacement.frame(panel: CGSize(width: 320, height: 380), anchor: CGRect(x: 260, y: 95, width: 30, height: 21), menu: CGSize(width: 168, height: 110))
        XCTAssertEqual(frame.minY, 124)
        XCTAssertEqual(frame.maxX, 290)
    }
    func testNearBottomFlipsAboveWithGap() {
        let anchor = CGRect(x: 260, y: 330, width: 30, height: 21)
        let frame = CountdownPopoverPlacement.frame(panel: CGSize(width: 320, height: 380), anchor: anchor, menu: CGSize(width: 168, height: 110))
        XCTAssertEqual(frame.maxY, anchor.minY - 8)
        XCTAssertGreaterThanOrEqual(frame.minX, 8)
    }
    func testClampsVeryTallMenuInsidePanel() {
        let frame = CountdownPopoverPlacement.frame(panel: CGSize(width: 320, height: 380), anchor: CGRect(x: 10, y: 150, width: 30, height: 100), menu: CGSize(width: 168, height: 320))
        XCTAssertGreaterThanOrEqual(frame.minY, 8)
        XCTAssertLessThanOrEqual(frame.maxY, 372)
        XCTAssertGreaterThanOrEqual(frame.minX, 8)
    }
    func testStaysInsidePanelEvenWhenScreenHasRoom() {
        let panel = CGRect(x: 0, y: 200, width: 320, height: 380)
        let anchor = CGRect(x: 260, y: 460, width: 30, height: 21)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = CountdownPopoverPlacement.screenFrame(panel: panel, anchor: anchor, screen: screen, menu: CGSize(width: 168, height: 110))
        XCTAssertGreaterThanOrEqual(frame.minX, panel.minX + 8)
        XCTAssertLessThanOrEqual(frame.maxX, panel.maxX - 8)
        XCTAssertEqual(frame.maxY, anchor.minY - 8)
    }
    func testFallsBackInsidePanelWhenRightSideIsNarrow() {
        let panel = CGRect(x: 0, y: 200, width: 320, height: 380)
        let anchor = CGRect(x: 260, y: 210, width: 30, height: 21)
        let screen = CGRect(x: 0, y: 0, width: 340, height: 800)
        let frame = CountdownPopoverPlacement.screenFrame(panel: panel, anchor: anchor, screen: screen, menu: CGSize(width: 168, height: 110))
        XCTAssertLessThanOrEqual(frame.maxX, panel.maxX - 8)
        XCTAssertGreaterThanOrEqual(frame.minY, panel.minY + 8)
        XCTAssertGreaterThan(frame.minY, anchor.maxY)
    }
    func testResizingAboveKeepsEdgeNearAnchorAndDoesNotFlip() {
        let panel = CGRect(x: 0, y: 200, width: 320, height: 380)
        let anchor = CGRect(x: 260, y: 299, width: 30, height: 21)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let preset = CountdownPopoverPlacement.screenFrame(panel: panel, anchor: anchor, screen: screen, menu: CGSize(width: 168, height: 104), referenceHeight: 104)
        let custom = CountdownPopoverPlacement.screenFrame(panel: panel, anchor: anchor, screen: screen, menu: CGSize(width: 168, height: 40), referenceHeight: 104)
        XCTAssertEqual(preset.minY, anchor.maxY + 8)
        XCTAssertEqual(custom.minY, preset.minY)
        XCTAssertEqual(custom.minX, preset.minX)
        XCTAssertEqual(custom.height, 40)
    }
    func testResizingBelowKeepsEdgeNearAnchor() {
        let panel = CGRect(x: 0, y: 200, width: 320, height: 380)
        let anchor = CGRect(x: 260, y: 460, width: 30, height: 21)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let preset = CountdownPopoverPlacement.screenFrame(panel: panel, anchor: anchor, screen: screen, menu: CGSize(width: 168, height: 104), referenceHeight: 104)
        let custom = CountdownPopoverPlacement.screenFrame(panel: panel, anchor: anchor, screen: screen, menu: CGSize(width: 168, height: 40), referenceHeight: 104)
        XCTAssertEqual(preset.maxY, anchor.minY - 8)
        XCTAssertEqual(custom.maxY, preset.maxY)
        XCTAssertEqual(custom.minX, preset.minX)
    }
}

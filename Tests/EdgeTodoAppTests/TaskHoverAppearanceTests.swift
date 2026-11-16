import XCTest
@testable import EdgeTodoApp

final class TaskHoverAppearanceTests: XCTestCase {
    func testTodayHoverFollowsActualMaterialAndKeepsDragFeedback() {
        XCTAssertTrue(TaskHoverAppearance.useSubtleHighlight(isHovered: true, isToday: true, isDragging: false, isPinned: true, reduceTransparency: false))
        XCTAssertFalse(TaskHoverAppearance.useSubtleHighlight(isHovered: true, isToday: true, isDragging: false, isPinned: false, reduceTransparency: false))
        XCTAssertFalse(TaskHoverAppearance.useSubtleHighlight(isHovered: true, isToday: true, isDragging: false, isPinned: true, reduceTransparency: true))
        XCTAssertFalse(TaskHoverAppearance.useSubtleHighlight(isHovered: true, isToday: true, isDragging: true, isPinned: true, reduceTransparency: false))
        XCTAssertFalse(TaskHoverAppearance.useSubtleHighlight(isHovered: false, isToday: true, isDragging: false, isPinned: true, reduceTransparency: false))
        XCTAssertTrue(TaskHoverAppearance.showBackground(isHovered: true, isToday: true, isDragging: false, isPinned: false, reduceTransparency: false))
        XCTAssertFalse(TaskHoverAppearance.showBackground(isHovered: true, isToday: true, isDragging: false, isPinned: true, reduceTransparency: false))
        XCTAssertTrue(TaskHoverAppearance.showBackground(isHovered: true, isToday: true, isDragging: false, isPinned: true, reduceTransparency: true))
        XCTAssertTrue(TaskHoverAppearance.showBackground(isHovered: true, isToday: true, isDragging: true, isPinned: true, reduceTransparency: false))
        XCTAssertTrue(TaskHoverAppearance.showBackground(isHovered: true, isToday: false, isDragging: false, isPinned: true, reduceTransparency: false))
        XCTAssertFalse(TaskHoverAppearance.showBackground(isHovered: false, isToday: true, isDragging: false, isPinned: false, reduceTransparency: false))
    }
}

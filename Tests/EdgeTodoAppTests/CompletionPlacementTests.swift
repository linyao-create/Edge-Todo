import XCTest
@testable import EdgeTodoApp

final class CompletionPlacementTests: XCTestCase {
    func testRecentlyCompletedRowsStayInOriginalSlotsUntilReleased() {
        let a = Todo(text: "甲", category: .today)
        let b = Todo(text: "乙", category: .today)
        let c = Todo(text: "丙", category: .today)
        let draft = Todo(text: "", category: .today)
        let afterSave = [c, draft, a, b]
        let held = [a.id: CompletionPlacement.Hold(index: 0, wasCompleted: false),
                    b.id: CompletionPlacement.Hold(index: 1, wasCompleted: false)]
        XCTAssertEqual(CompletionPlacement.apply(afterSave, holds: held).map(\.id), [a.id, b.id, c.id, draft.id])
        XCTAssertEqual(CompletionPlacement.apply(afterSave, holds: [:]).map(\.id), afterSave.map(\.id))
    }

    func testPlacementPreservesAllRowsEvenWhenOriginalIndexIsOutOfRange() {
        let a = Todo(text: "甲", category: .today)
        let b = Todo(text: "乙", category: .today)
        XCTAssertEqual(CompletionPlacement.apply([a, b], holds: [a.id: .init(index: 99, wasCompleted: false)]).map(\.id), [b.id, a.id])
    }
}

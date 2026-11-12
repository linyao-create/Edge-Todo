import XCTest
@testable import EdgeTodoApp

final class EdgeTodoAppTests: XCTestCase {
    func testTodoAppModuleLoads() {
        XCTAssertEqual(AppIdentity.name, "Edge Todo")
    }

    func testAddingTodoTrimsTextAndPersistsIt() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = TodoStore(fileURL: file)

        let todo = try store.add(text: "  买牛奶  ")
        let loaded = try store.load()

        XCTAssertEqual(todo.text, "买牛奶")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, todo.id)
        XCTAssertEqual(loaded[0].text, todo.text)
        XCTAssertEqual(loaded[0].isCompleted, todo.isCompleted)
        XCTAssertLessThan(
            abs(loaded[0].createdAt.timeIntervalSince(todo.createdAt)),
            0.001
        )
    }

    func testEmptyTodoIsRejected() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = TodoStore(fileURL: file)

        XCTAssertThrowsError(try store.add(text: "   "))
    }

    func testMissingFileLoadsAsEmptyInbox() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = TodoStore(fileURL: file)

        XCTAssertEqual(try store.load(), [])
    }

    func testMultipleTodosKeepInsertionOrder() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = TodoStore(fileURL: file)

        _ = try store.add(text: "第一件事")
        _ = try store.add(text: "第二件事")

        XCTAssertEqual(try store.load().map(\.text), ["第一件事", "第二件事"])
    }

    func testDeletingTodoRemovesItFromPersistence() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = TodoStore(fileURL: file)
        let first = try store.add(text: "保留")
        let second = try store.add(text: "删除")

        try store.delete(id: second.id)

        let remaining = try store.load()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, first.id)
        XCTAssertEqual(remaining[0].text, "保留")
    }

    func testUpdatingTodoPersistsTheNewText() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = TodoStore(fileURL: file)
        let todo = try store.add(text: "原来的内容")

        let updated = try store.update(id: todo.id, text: "修改后的内容")

        XCTAssertEqual(updated.text, "修改后的内容")
        XCTAssertEqual(try store.load().first?.text, "修改后的内容")
    }

    func testDeleteKeyOnlyDeletesEmptyTodoRow() {
        XCTAssertFalse(TodoEditingBehavior.shouldDeleteRow(text: "买牛奶"))
        XCTAssertTrue(TodoEditingBehavior.shouldDeleteRow(text: ""))
        XCTAssertTrue(TodoEditingBehavior.shouldDeleteRow(text: "   "))
    }

    func testPinPreventsCollapseWithoutOverridingTemporaryHold() {
        let scheduler = TestEdgeScheduler()
        let controller = EdgeInteractionController(scheduler: scheduler)
        controller.reveal()
        controller.setPinned(true)
        controller.pointerExited()
        scheduler.runPending()
        XCTAssertEqual(controller.state, .expanded)
        controller.setHeldOpen(true)
        controller.setPinned(false)
        controller.pointerExited()
        scheduler.runPending()
        XCTAssertEqual(controller.state, .expanded)
        controller.setHeldOpen(false)
        controller.pointerExited()
        scheduler.runPending()
        XCTAssertEqual(controller.state, .collapsed)
    }

    func testPinSettingsAreIndependentPerDisplayAndSurviveStoreRecreation() {
        let suite = "EdgeTodo.pin.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PanelSelectionStore(defaults: defaults)
        XCTAssertFalse(store.isPinned(displayID: "display-a"))
        store.setPinned(true, displayID: "display-a")
        XCTAssertTrue(PanelSelectionStore(defaults: defaults).isPinned(displayID: "display-a"))
        XCTAssertFalse(store.isPinned(displayID: "display-b"))
        store.setPinned(false, displayID: "display-a")
        XCTAssertFalse(store.isPinned(displayID: "display-a"))
    }

    func testPointerEntryExpandsAfterDwell() {
        let scheduler = TestEdgeScheduler()
        let controller = EdgeInteractionController(scheduler: scheduler)

        controller.pointerEntered()

        XCTAssertEqual(controller.state, .collapsed)
        scheduler.runPending()
        XCTAssertEqual(controller.state, .expanded)
    }

    func testPointerTimingUsesResponsiveDurations() {
        let scheduler = TestEdgeScheduler()
        let controller = EdgeInteractionController(scheduler: scheduler)

        controller.pointerEntered()
        XCTAssertEqual(scheduler.lastScheduledInterval, 0.18, accuracy: 0.001)
        scheduler.runPending()

        controller.pointerExited()
        XCTAssertEqual(scheduler.lastScheduledInterval, 0.25, accuracy: 0.001)
    }

    func testPointerExitBeforeDwellKeepsPanelCollapsed() {
        let scheduler = TestEdgeScheduler()
        let controller = EdgeInteractionController(scheduler: scheduler)

        controller.pointerEntered()
        controller.pointerExited()
        scheduler.runPending()

        XCTAssertEqual(controller.state, .collapsed)
    }

    func testPointerExitAfterExpansionCollapsesPanel() {
        let scheduler = TestEdgeScheduler()
        let controller = EdgeInteractionController(scheduler: scheduler)

        controller.pointerEntered()
        scheduler.runPending()
        controller.pointerExited()

        XCTAssertEqual(controller.state, .expanded)
        scheduler.runPending()
        XCTAssertEqual(controller.state, .collapsed)
    }

    func testTitleDialogKeepsPanelOpenUntilItCloses() {
        let scheduler = TestEdgeScheduler()
        let controller = EdgeInteractionController(scheduler: scheduler)
        controller.reveal()
        controller.setHeldOpen(true)
        controller.pointerExited()
        scheduler.runPending()
        XCTAssertEqual(controller.state, .expanded)

        controller.setHeldOpen(false)
        controller.pointerExited()
        scheduler.runPending()
        XCTAssertEqual(controller.state, .collapsed)
    }

    func testNonEmptySubmissionKeepsPanelExpandedAndEmitsText() {
        let scheduler = TestEdgeScheduler()
        var submittedText: String?
        let controller = EdgeInteractionController(scheduler: scheduler) {
            submittedText = $0
            return true
        }
        controller.pointerEntered()
        scheduler.runPending()

        controller.submit(text: "  回电话  ")

        XCTAssertEqual(submittedText, "回电话")
        XCTAssertEqual(controller.state, .expanded)
    }

    func testBlankSubmissionKeepsPanelExpanded() {
        let scheduler = TestEdgeScheduler()
        let controller = EdgeInteractionController(scheduler: scheduler)
        controller.pointerEntered()
        scheduler.runPending()

        controller.submit(text: "   ")

        XCTAssertEqual(controller.state, .expanded)
    }

    func testFailedSubmissionKeepsPanelExpanded() {
        let scheduler = TestEdgeScheduler()
        let controller = EdgeInteractionController(scheduler: scheduler) { _ in
            false
        }
        controller.pointerEntered()
        scheduler.runPending()

        controller.submit(text: "无法保存的待办")

        XCTAssertEqual(controller.state, .expanded)
    }
}

private final class TestEdgeScheduler: EdgeScheduler {
    private var pendingAction: (() -> Void)?
    private(set) var lastScheduledInterval: TimeInterval = 0

    @discardableResult
    func schedule(after interval: TimeInterval, _ action: @escaping () -> Void) -> EdgeCancellable {
        lastScheduledInterval = interval
        pendingAction = action
        return TestCancellation { [weak self] in self?.pendingAction = nil }
    }

    func runPending() {
        let action = pendingAction
        pendingAction = nil
        action?()
    }
}

private final class TestCancellation: EdgeCancellable {
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel()
    }
}

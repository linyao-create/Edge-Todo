import AppKit
import SwiftUI
import XCTest
@testable import EdgeTodoApp

final class DualPanelStoreTests: XCTestCase {
    private var directory: URL!
    private var store: TodoStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testLegacyItemsDefaultToTodayWithoutLosingContent() throws {
        let id = UUID()
        let json = """
        [{"id":"\(id)","text":"旧待办","createdAt":"2026-10-06T09:24:40.822Z","isCompleted":false}]
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("todos.json"))
        let item = try XCTUnwrap(store.load().first)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.text, "旧待办")
        XCTAssertEqual(item.category, .today)
    }

    func testCategoriesPersistAndRemainIndependent() throws {
        _ = try store.add(text: "今日的事")
        _ = try store.add(text: "灵感", category: .notes)
        let items = try store.load()
        XCTAssertEqual(items.filter { $0.category == .today }.map(\.text), ["今日的事"])
        XCTAssertEqual(items.filter { $0.category == .notes }.map(\.text), ["灵感"])
    }

    func testImportNoteIsIdempotentAndKeepsTheFirstSavedContent() throws {
        let id = UUID()
        let first = try store.importNote(id: id, text: "手机分享的灵感\nhttps://example.com")
        let retried = try store.importNote(id: id, text: "重复的导入")

        XCTAssertEqual(first.id, id)
        XCTAssertEqual(first.category, .notes)
        XCTAssertEqual(retried.id, first.id)
        XCTAssertEqual(retried.text, first.text)
        XCTAssertEqual(try store.load().filter { $0.id == id }.count, 1)
    }

    func testMoveKeepsIdentityAndDateAndAppendsAtDestination() throws {
        let task = try store.add(text: "改成随记")
        let note = try store.add(text: "已有随记", category: .notes)
        _ = try store.updateCompletion(id: task.id, isCompleted: true)
        let moved = try store.move(id: task.id, to: .notes)
        XCTAssertEqual(moved.id, task.id)
        XCTAssertEqual(moved.createdAt.timeIntervalSince(task.createdAt), 0, accuracy: 0.001)
        XCTAssertFalse(moved.isCompleted)
        let items = try store.load()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.id), [note.id, task.id])
        let returned = try store.move(id: task.id, to: .today)
        XCTAssertFalse(returned.isCompleted)
        XCTAssertEqual(returned.category, .today)
    }

    func testEmptyEditPersistsAndDeletedItemCannotBeResurrectedByStaleEdit() throws {
        let task = try store.add(text: "逐字删完")
        _ = try store.saveDraft(id: task.id, text: "", allowInsert: false)
        XCTAssertEqual(try store.load().first?.text, "")
        try store.delete(id: task.id)
        XCTAssertThrowsError(try store.saveDraft(id: task.id, text: "旧文字", allowInsert: false)) {
            XCTAssertEqual($0 as? TodoStoreError, .notFound)
        }
        XCTAssertEqual(try store.load(), [])
    }

    func testDraftCharactersAndWhitespaceStayExactlyAsTyped() throws {
        let id = UUID()
        _ = try store.saveDraft(id: id, text: "一", category: .notes)
        XCTAssertEqual(try store.load().first?.text, "一")
        _ = try store.saveDraft(id: id, text: "一二 ", allowInsert: false)
        XCTAssertEqual(try store.load().first?.text, "一二 ")
        XCTAssertEqual(try store.load().first?.category, .notes)
    }

    func testNewRowCanBeInsertedAfterAnExistingRow() throws {
        let first = try store.add(text: "一")
        let second = try store.add(text: "二")
        let inserted = try store.saveDraft(id: UUID(), text: "中间", insertAfter: first.id)
        XCTAssertEqual(try store.load().map(\.id), [first.id, inserted.id, second.id])
    }

    func testUnfinishedTasksSurviveDateChangesAndCompletionCanBeReversed() throws {
        let old = Todo(text: "昨天未完成", createdAt: Date(timeIntervalSince1970: 1))
        try store.save([old])
        XCTAssertEqual(try store.load().map(\.id), [old.id])
        _ = try store.updateCompletion(id: old.id, isCompleted: true)
        XCTAssertTrue(try XCTUnwrap(store.load().first).isCompleted)
        _ = try store.updateCompletion(id: old.id, isCompleted: false)
        XCTAssertFalse(try XCTUnwrap(store.load().first).isCompleted)
    }

    func testSelectionDefaultsToTodayAndSurvivesNewStoreInstance() throws {
        let suite = "EdgeTodoTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = PanelSelectionStore(defaults: defaults)
        XCTAssertEqual(selection.category, .today)
        selection.select(.notes)
        XCTAssertEqual(PanelSelectionStore(defaults: defaults).category, .notes)
        selection.select(.today)
        XCTAssertEqual(PanelSelectionStore(defaults: defaults).category, .today)
    }
}

@MainActor
final class DualPanelControllerTests: XCTestCase {
    func testTodayDraftAppearsAfterActiveAndBeforeCompleted() throws {
        let (controller, store, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let first = try store.add(text: "未完成一")
        let completed = try store.add(text: "已完成")
        let second = try store.add(text: "未完成二")
        _ = try store.updateCompletion(id: completed.id, isCompleted: true)
        controller.refresh()
        let rows = controller.visibleRows
        XCTAssertEqual(rows.map(\.id).prefix(2), [first.id, second.id])
        XCTAssertEqual(rows[2].text, "")
        XCTAssertEqual(rows[3].id, completed.id)
    }

    func testDraftFocusSurvivesCompletionRefresh() throws {
        let (controller, store, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let item = try store.add(text: "未完成")
        controller.refresh()
        let draft = try XCTUnwrap(controller.visibleRows.last)
        controller.beginEditing(todoID: draft.id)
        controller.toggleCompletion(todoID: item.id)
        XCTAssertEqual(controller.focusedRowID, draft.id)
        XCTAssertEqual(controller.visibleRows.first?.id, draft.id)
    }

    func testCompletingCurrentDraftCreatesASeparateInputBeforeCompleted() throws {
        let (controller, _, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let draftID = try XCTUnwrap(controller.visibleRows.last?.id)
        controller.updateEditingText(todoID: draftID, text: "刚添加")
        controller.toggleCompletion(todoID: draftID)
        XCTAssertEqual(controller.visibleRows.count, 2)
        XCTAssertEqual(controller.visibleRows.first?.text, "")
        XCTAssertEqual(controller.visibleRows.last?.id, draftID)
    }

    func testDraftStaysInPlaceAndReturnCreatesNextRow() throws {
        let (controller, _, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let id = try XCTUnwrap(controller.visibleRows.last?.id)
        controller.updateEditingText(todoID: id, text: "随手写")
        XCTAssertEqual(controller.visibleRows.map(\.id), [id])
        XCTAssertEqual(controller.todos.first?.text, "随手写")
        controller.submitRow(todoID: id)
        XCTAssertEqual(controller.visibleRows.count, 2)
        XCTAssertEqual(controller.visibleRows.first?.id, id)
        XCTAssertEqual(controller.visibleRows.last?.text, "")
        XCTAssertEqual(controller.focusedRowID, controller.visibleRows.last?.id)
    }

    func testDeleteEmptyRowRemovesMarkerAndDoesNotReturnAfterRefresh() throws {
        let (controller, store, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let id = try XCTUnwrap(controller.visibleRows.last?.id)
        controller.updateEditingText(todoID: id, text: "删除")
        controller.updateEditingText(todoID: id, text: "")
        XCTAssertTrue(controller.visibleRows.contains { $0.id == id })
        controller.deleteEmptyRow(todoID: id)
        controller.refresh()
        XCTAssertFalse(controller.visibleRows.contains { $0.id == id })
        XCTAssertEqual(try store.load(), [])
    }

    func testSwitchKeepsSavedDraftAndLastSelection() throws {
        let (controller, store, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let taskID = try XCTUnwrap(controller.visibleRows.last?.id)
        controller.updateEditingText(todoID: taskID, text: "未回车的待办")
        controller.selectCategory(.notes)
        XCTAssertEqual(controller.selectedCategory, .notes)
        XCTAssertFalse(controller.visibleRows.contains { $0.id == taskID })
        let noteID = try XCTUnwrap(controller.visibleRows.last?.id)
        controller.updateEditingText(todoID: noteID, text: "未回车的随记")
        controller.selectCategory(.today)
        XCTAssertEqual(controller.visibleRows.first?.text, "未回车的待办")
        XCTAssertEqual(try store.load().count, 2)
    }

    func testMovingItemDoesNotSwitchCurrentPanelAndRefreshFindsDestination() throws {
        let (controller, store, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let id = try XCTUnwrap(controller.visibleRows.last?.id)
        controller.updateEditingText(todoID: id, text: "转为随记")
        controller.moveItem(todoID: id)
        XCTAssertEqual(controller.selectedCategory, .today)
        XCTAssertFalse(controller.visibleRows.contains { $0.id == id })
        XCTAssertEqual(try store.load().first?.category, .notes)
        controller.selectCategory(.notes)
        XCTAssertEqual(controller.visibleRows.first?.id, id)
    }

    func testReturnInMiddlePlacesTodayInputAfterUncompletedRows() throws {
        let (controller, store, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let first = try store.add(text: "第一条")
        let last = try store.add(text: "最后一条")
        controller.refresh()
        controller.submitRow(todoID: first.id)
        let newID = try XCTUnwrap(controller.focusedRowID)
        XCTAssertEqual(controller.visibleRows.map(\.id), [first.id, last.id, newID])
        controller.updateEditingText(todoID: newID, text: "新插入的内容")
        XCTAssertEqual(try store.load().map(\.id), [first.id, last.id, newID])
    }

    func testOtherScreenRefreshesAndDeletedItemRejectsLateCallback() throws {
        let (first, store, cleanup) = try makeController()
        defer { first.dispose(); cleanup() }
        let second = EdgePanelWindowController(store: store, screen: try XCTUnwrap(NSScreen.screens.first))
        defer { second.dispose() }
        let id = try XCTUnwrap(first.visibleRows.last?.id)
        first.updateEditingText(todoID: id, text: "共享的内容")
        XCTAssertEqual(second.todos.first?.id, id)
        second.updateEditingText(todoID: id, text: "")
        second.deleteEmptyRow(todoID: id)
        first.updateEditingText(todoID: id, text: "旧内容延迟回调")
        XCTAssertEqual(try store.load(), [])
        XCTAssertFalse(first.visibleRows.contains { $0.id == id })
    }

    func testDisposingScreenPanelDoesNotReopenItsTriggerOrRetainContent() throws {
        let (controller, _, cleanup) = try makeController()
        defer { cleanup() }
        let panel = try XCTUnwrap(NSApp.windows.first {
            ($0.contentView as? NSHostingView<EdgePanelView>)?.rootView.controller === controller
        })
        controller.dispose()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.contentView)
    }

    private func makeController() throws -> (EdgePanelWindowController, TodoStore, () -> Void) {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        let suite = "EdgeTodoControllerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = EdgePanelWindowController(store: store, screen: screen,
            selectionStore: PanelSelectionStore(defaults: defaults))
        return (controller, store, {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        })
    }
}

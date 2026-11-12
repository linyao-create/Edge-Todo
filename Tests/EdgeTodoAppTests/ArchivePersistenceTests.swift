import XCTest
@testable import EdgeTodoApp

final class ArchivePersistenceTests: XCTestCase {
    private func store() -> TodoStore {
        TodoStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func testDeletedUUIDCannotBeReinsertedByStaleDraft() throws {
        let store = store()
        let todo = try store.add(text: "保留历史")
        try store.delete(id: todo.id)
        XCTAssertThrowsError(try store.saveDraft(id: todo.id, text: "迟到回调", allowInsert: true))
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testDeletionRetainsLastNonemptyTextAndPublicSavePreservesTombstone() throws {
        let store = store()
        let todo = try store.add(text: "历史正文")
        _ = try store.saveDraft(id: todo.id, text: " \n", allowInsert: false)
        try store.delete(id: todo.id)
        try store.save([])
        let retained = try XCTUnwrap(store.loadArchive().first)
        XCTAssertEqual(retained.archiveText, "历史正文")
        XCTAssertTrue(retained.isDeleted)
        try store.save([todo])
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testCompletionVisibilityUsesCalendarDayAndMoveClearsCompletion() throws {
        let store = store()
        let todo = try store.add(text: "完成")
        let completed = try store.updateCompletion(id: todo.id, isCompleted: true)
        let date = try XCTUnwrap(completed.completedAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertTrue(completed.isVisible(at: date, calendar: calendar))
        XCTAssertFalse(completed.isVisible(at: calendar.date(byAdding: .day, value: 1, to: date)!, calendar: calendar))
        XCTAssertNil(try store.updateCompletion(id: todo.id, isCompleted: false).completedAt)
        _ = try store.updateCompletion(id: todo.id, isCompleted: true)
        let moved = try store.move(id: todo.id, to: .notes)
        XCTAssertNil(moved.completedAt)
        XCTAssertFalse(moved.isCompleted)
    }

    func testLegacyCompletionIsAdoptedOnceAndCorruptDataThrows() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID()
        let data = Data("[{\"id\":\"\(id)\",\"text\":\"旧任务\",\"createdAt\":\"2025-01-01T00:00:00.000Z\",\"isCompleted\":true}]".utf8)
        try data.write(to: file)
        let first = try XCTUnwrap(TodoStore(fileURL: file).load().first)
        XCTAssertNotNil(first.completedAt)
        XCTAssertEqual(first.completedAt, try TodoStore(fileURL: file).load().first?.completedAt)
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try TodoStore(fileURL: file).loadArchive())
    }

    func testDeletionTimestampPersistsAndLegacyTombstonesRemainReadable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixedNow = Date(timeIntervalSince1970: 1_791_360_000)
        let store = TodoStore(fileURL: file, now: { fixedNow })
        let todo = try store.add(text: "归档删除时间")
        try store.delete(id: todo.id)
        XCTAssertEqual(try store.loadArchive().first?.deletedAt, fixedNow)

        let legacy = Data("""
        [{"id":"\(UUID())","text":"旧删除","createdAt":"2025-01-01T00:00:00.000Z","isCompleted":false,"category":"today","isDeleted":true}]
        """.utf8)
        try legacy.write(to: file)
        let oldDeleted = try XCTUnwrap(TodoStore(fileURL: file).loadArchive().first)
        XCTAssertTrue(oldDeleted.isDeleted)
        XCTAssertNil(oldDeleted.deletedAt)
        XCTAssertEqual(oldDeleted.archiveText, "旧删除")
    }

    func testIncrementalErasureRetainsWholeBodyAndReplacementResetsBaseline() throws {
        let store = store()
        let todo = try store.add(text: "完整记录")
        for text in ["完整记", "完整", "完", ""] {
            _ = try store.saveDraft(id: todo.id, text: text, allowInsert: false)
        }
        XCTAssertEqual(try store.loadArchive().first?.archiveText, "完整记录")
        _ = try store.saveDraft(id: todo.id, text: "新正文", allowInsert: false)
        for text in ["新正", "新", ""] {
            _ = try store.saveDraft(id: todo.id, text: text, allowInsert: false)
        }
        try store.delete(id: todo.id)
        XCTAssertEqual(try store.loadArchive().first?.archiveText, "新正文")
    }
}

import XCTest
@testable import EdgeTodoApp
final class TaskReorderTests: XCTestCase {
    func testRestoringCompletedTaskPreservesReorderingOfRemainingTasks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TodoStore(fileURL: dir.appendingPathComponent("todos.json"))
        let a = try store.add(text: "一")
        let b = try store.add(text: "二")
        let c = try store.add(text: "三")
        _ = try store.updateCompletion(id: b.id, isCompleted: true)
        try store.reorderActiveToday([c.id, a.id])
        _ = try store.updateCompletion(id: b.id, isCompleted: false)
        XCTAssertEqual(try store.load().map(\.id), [c.id, b.id, a.id])
    }

    func testCompletionRestoresManualOrderWithoutDisturbingOtherTasks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("todos.json")
        let store = TodoStore(fileURL: url)
        let a = try store.add(text: "一")
        let b = try store.add(text: "二")
        let c = try store.add(text: "三")
        try store.reorderActiveToday([c.id, a.id, b.id])
        _ = try store.updateCompletion(id: a.id, isCompleted: true)
        _ = try store.updateCompletion(id: a.id, isCompleted: false)
        XCTAssertEqual(try TodoStore(fileURL: url).load().map(\.id), [c.id, a.id, b.id])
    }

    func testReorderingPersistsAndPreservesOtherItems() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("todos.json")
        let store = TodoStore(fileURL: url)
        let a = try store.add(text: "一")
        let b = try store.add(text: "二")
        let c = try store.add(text: "三")
        let note = try store.add(text: "随记", category: .notes)
        _ = try store.updateCompletion(id: c.id, isCompleted: true)
        try store.reorderActiveToday([b.id, a.id])
        let saved = try TodoStore(fileURL: url).load()
        XCTAssertEqual(saved.filter { $0.category == .today && !$0.isCompleted }.map(\.id), [b.id, a.id])
        XCTAssertTrue(saved.contains { $0.id == c.id && $0.isCompleted })
        XCTAssertTrue(saved.contains { $0.id == note.id && $0.category == .notes })
    }
}

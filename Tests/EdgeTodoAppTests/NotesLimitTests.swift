import Foundation
import XCTest
@testable import EdgeTodoApp

final class NotesLimitTests: XCTestCase {
    func testLimitRejectsNewNotesAndPreservesExistingContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TodoStore(fileURL: root.appendingPathComponent("todos.json"))
        for n in 0..<20 { try store.add(text: "随记\(n)", category: .notes) }
        let task = try store.add(text: "待办", category: .today)
        XCTAssertThrowsError(try store.add(text: "第21条", category: .notes))
        XCTAssertThrowsError(try store.move(id: task.id, to: .notes))
        XCTAssertThrowsError(try store.importNote(id: UUID(), text: "网页\nhttps://example.com/?q=中文"))
        XCTAssertThrowsError(try store.saveDraft(id: UUID(), text: "手动输入", category: .notes))
        XCTAssertEqual(try store.load().filter { $0.category == .notes }.count, 20)
        XCTAssertEqual(try store.load().first(where: { $0.id == task.id })?.category, .today)
        let first = try XCTUnwrap(store.load().first { $0.category == .notes })
        _ = try store.update(id: first.id, text: "修改已有内容")
        try store.delete(id: first.id)
        _ = try store.move(id: task.id, to: .notes)
        XCTAssertEqual(try store.load().filter { $0.category == .notes }.count, 20)
    }

    func testDuplicateImportDoesNotConsumeCapacity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TodoStore(fileURL: root.appendingPathComponent("todos.json"))
        let id = UUID()
        _ = try store.importNote(id: id, text: "链接 https://example.com")
        for n in 0..<19 { try store.add(text: "\(n)", category: .notes) }
        XCTAssertNoThrow(try store.importNote(id: id, text: "重复"))
        XCTAssertEqual(try store.load().count, 20)
    }
    func testExistingMoreThanTwentyCanBeEditedAndReducedButNotIncreased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("todos.json")
        let store = TodoStore(fileURL: file)
        for n in 0..<20 { try store.add(text: "\(n)", category: .notes) }
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        var extra = raw[0]
        extra["id"] = UUID().uuidString
        extra["text"] = "已有超额内容"
        raw.append(extra)
        try JSONSerialization.data(withJSONObject: raw).write(to: file)
        let first = try XCTUnwrap(store.load().first)
        _ = try store.update(id: first.id, text: "仍可编辑")
        XCTAssertThrowsError(try store.add(text: "不得增加", category: .notes))
        try store.delete(id: first.id)
        XCTAssertEqual(try store.load().count, 20)
    }

    func testBlankRowsDoNotCountButReactivatingOneAtCapacityIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TodoStore(fileURL: root.appendingPathComponent("todos.json"))
        let blank = try store.add(text: "稍后清空", category: .notes)
        _ = try store.saveDraft(id: blank.id, text: "  ", category: .notes)
        for n in 0..<20 { try store.add(text: "\(n)", category: .notes) }
        XCTAssertThrowsError(try store.saveDraft(id: blank.id, text: "重新输入", category: .notes))
        XCTAssertEqual(try store.load().first(where: { $0.id == blank.id })?.text, "  ")
    }

}

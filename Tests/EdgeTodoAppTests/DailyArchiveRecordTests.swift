import XCTest
@testable import EdgeTodoApp

final class DailyArchiveRecordTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return formatter.date(from: string + "T12:00:00+08:00")!
    }

    func testSnapshotsGroupItemsByDayAndShowCarryoverCompletionDeletionAndNotes() throws {
        let day1 = date("2026-10-05")
        let day2 = date("2026-10-06")
        let day3 = date("2026-10-07")
        let open = Todo(text: "持续未完成", createdAt: day1)
        let completedLater = Todo(text: "后来完成", createdAt: day1,
            isCompleted: true, category: .today)
        var completed = completedLater
        completed.completedAt = day2
        let deletedLater = Todo(text: "删除的事项", createdAt: day2)
        var deleted = deletedLater
        deleted.isDeleted = true
        deleted.deletedAt = day3
        let note = Todo(text: "灵感记录", createdAt: day1, category: .notes)

        let snapshots = DailyArchiveRecord.snapshots(todos: [open, completed, deleted, note],
            through: day3, calendar: calendar, archiveStartDate: nil)
        XCTAssertEqual(snapshots.map(\.dateKey), ["2026-10-05", "2026-10-06", "2026-10-07"])

        let first = try XCTUnwrap(snapshots.first)
        XCTAssertTrue(first.todoText.contains("☐ 持续未完成"))
        XCTAssertTrue(first.todoText.contains("☐ 后来完成"))
        XCTAssertTrue(first.notesText.contains("• 灵感记录"))

        let second = snapshots[1]
        XCTAssertTrue(second.todoText.contains("☑ 后来完成"))
        XCTAssertTrue(second.todoText.contains("☐ 删除的事项"))

        let third = snapshots[2]
        XCTAssertTrue(third.todoText.contains("☐ 持续未完成"))
        XCTAssertTrue(third.todoText.contains("已删除"))
        XCTAssertTrue(third.todoText.contains("删除的事项"))
    }

    func testArchiveStartDateConsolidatesPreexistingItemsIntoFirstArchiveDay() throws {
        let previousDay = date("2026-10-06")
        let archiveStart = date("2026-10-07")
        let nextDay = date("2026-10-08")
        let open = Todo(text: "原有未完成", createdAt: previousDay)
        var completed = Todo(text: "原有已完成", createdAt: previousDay, isCompleted: true)
        completed.completedAt = previousDay
        var deleted = Todo(text: "原有已删除", createdAt: previousDay)
        deleted.isDeleted = true
        deleted.deletedAt = previousDay
        let note = Todo(text: "原有随记", createdAt: previousDay, category: .notes)

        let snapshots = DailyArchiveRecord.snapshots(todos: [open, completed, deleted, note],
            through: nextDay, calendar: calendar, archiveStartDate: archiveStart)

        XCTAssertEqual(snapshots.map(\.dateKey), ["2026-10-07", "2026-10-08"])
        let baseline = try XCTUnwrap(snapshots.first)
        XCTAssertTrue(baseline.todoText.contains("☐ 原有未完成"))
        XCTAssertTrue(baseline.todoText.contains("☑ 原有已完成"))
        XCTAssertTrue(baseline.todoText.contains("原有已删除"))
        XCTAssertEqual(baseline.notesText, "• 原有随记")
    }

    func testDailyPayloadUsesDateAsStableKeyAndSeparateTodoAndNotesFields() throws {
        let day = date("2026-10-07")
        let todo = Todo(text: "今天要完成", createdAt: day)
        let note = Todo(text: "灵感", createdAt: day, category: .notes)
        let snapshot = try XCTUnwrap(DailyArchiveRecord.snapshots(todos: [todo, note],
            through: day, calendar: calendar).first)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.fieldData()) as? [String: String])

        XCTAssertEqual(fields["日期"], "2026-10-07")
        XCTAssertTrue(fields["今日待办"]?.contains("未完成") == true)
        XCTAssertEqual(fields["随记"], "• 灵感")
        XCTAssertEqual(snapshot.fingerprint, DailyArchiveRecord.snapshots(todos: [todo, note],
            through: day.addingTimeInterval(60), calendar: calendar).first?.fingerprint)
    }

    func testEmptyDayStillProducesAChronologicalDailyRow() throws {
        let day = date("2026-10-07")
        let row = try XCTUnwrap(DailyArchiveRecord.snapshots(todos: [], through: day, calendar: calendar).first)
        XCTAssertEqual(row.dateKey, "2026-10-07")
        XCTAssertEqual(row.todoText, "")
        XCTAssertEqual(row.notesText, "")
    }
}

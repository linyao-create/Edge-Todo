import Foundation
import CryptoKit

struct DailyArchiveRecord: Equatable, Sendable {
    let dateKey: String
    let todoText: String
    let notesText: String

    var fingerprint: String {
        SHA256.hash(data: (dateKey + "\n" + todoText + "\n" + notesText).data(using: .utf8)!)
            .map { String(format: "%02x", $0) }.joined()
    }

    func fieldData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "日期": dateKey,
            "今日待办": todoText,
            "随记": notesText
        ], options: [.sortedKeys])
    }

    static func snapshots(todos: [Todo], through date: Date, calendar: Calendar = .current,
                          archiveStartDate: Date? = nil) -> [DailyArchiveRecord] {
        let today = calendar.startOfDay(for: date)
        let archiveStartDay = archiveStartDate.map(calendar.startOfDay(for:))
        func archiveDay(_ value: Date) -> Date {
            let day = calendar.startOfDay(for: value)
            return archiveStartDay.map { max(day, $0) } ?? day
        }
        var days: Set<Date> = [today]
        for todo in todos {
            let createdDay = archiveDay(todo.createdAt)
            if createdDay <= today { days.insert(createdDay) }
            if let completedAt = todo.completedAt {
                let completedDay = archiveDay(completedAt)
                if completedDay <= today { days.insert(completedDay) }
            }
            if todo.isDeleted {
                let deletedDay = archiveDay(todo.deletedAt ?? todo.createdAt)
                if deletedDay <= today { days.insert(deletedDay) }
            }
        }

        return days.sorted().map { day in
            build(todos: todos, day: day, today: today, through: date,
                archiveStartDay: archiveStartDay, archiveDay: archiveDay, calendar: calendar)
        }
    }

    private static func build(todos: [Todo], day: Date, today: Date, through date: Date,
                              archiveStartDay: Date?, archiveDay: (Date) -> Date,
                              calendar: Calendar) -> DailyArchiveRecord {
        var completed: [String] = []
        var incomplete: [String] = []
        var deleted: [String] = []
        var notes: [String] = []

        func appendUnique(_ text: String, to values: inout [String]) {
            guard !text.isEmpty, !values.contains(text) else { return }
            values.append(text)
        }

        for todo in todos {
            let createdDay = archiveDay(todo.createdAt)
            let completionDay = todo.completedAt.map(archiveDay)
            let deletionDay = todo.deletedAt.map(archiveDay) ?? createdDay
            let text = todo.archiveText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if todo.category == .notes {
                if (todo.isDeleted ? deletionDay : createdDay) == day {
                    let label = todo.isDeleted ? "• [已删除] \(text)" : "• \(text)"
                    appendUnique(label, to: &notes)
                }
                continue
            }

            if todo.isDeleted {
                if deletionDay == day { appendUnique("• \(text)", to: &deleted) }
                else if createdDay == day { appendUnique("☐ \(text)", to: &incomplete) }
                continue
            }

            if day == archiveStartDay {
                if completionDay == day { appendUnique("☑ \(text)", to: &completed) }
                else if createdDay == day { appendUnique("☐ \(text)", to: &incomplete) }
            } else if day == today, todo.isVisible(at: date, calendar: calendar) {
                if todo.isCompleted { appendUnique("☑ \(text)", to: &completed) }
                else { appendUnique("☐ \(text)", to: &incomplete) }
            } else if createdDay == day {
                if completionDay == day { appendUnique("☑ \(text)", to: &completed) }
                else { appendUnique("☐ \(text)", to: &incomplete) }
            } else if completionDay == day {
                appendUnique("☑ \(text)", to: &completed)
            }
        }

        var sections: [String] = []
        if !completed.isEmpty { sections.append("已完成\n" + completed.joined(separator: "\n")) }
        if !incomplete.isEmpty { sections.append("未完成\n" + incomplete.joined(separator: "\n")) }
        if !deleted.isEmpty { sections.append("已删除\n" + deleted.joined(separator: "\n")) }

        return DailyArchiveRecord(dateKey: dateKey(for: day, calendar: calendar),
            todoText: sections.joined(separator: "\n\n"), notesText: notes.joined(separator: "\n"))
    }

    private static func dateKey(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

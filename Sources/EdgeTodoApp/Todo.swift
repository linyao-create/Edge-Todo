import Foundation

enum TodoCategory: String, Codable, CaseIterable, Sendable {
    case today
    case notes

    var title: String { self == .today ? "今日待办" : "随记" }
    var destination: TodoCategory { self == .today ? .notes : .today }
    var moveTitle: String { self == .today ? "→ 随记" : "→ 待办" }
}

struct Todo: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var text: String
    let createdAt: Date
    var isCompleted: Bool
    var category: TodoCategory
    var completedAt: Date?
    var isDeleted = false
    var deletedAt: Date?
    var lastNonemptyText: String = ""
    var archiveText: String { isDeleted || TodoEditingBehavior.shouldDeleteRow(text: text) ? lastNonemptyText : text }

    func isVisible(at date: Date, calendar: Calendar = .current) -> Bool {
        guard !isDeleted else { return false }
        guard category == .today, isCompleted, let completedAt else { return true }
        return calendar.startOfDay(for: completedAt) >= calendar.startOfDay(for: date)
    }

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        isCompleted: Bool = false,
        category: TodoCategory = .today
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.isCompleted = isCompleted
        self.category = category
        self.lastNonemptyText = TodoEditingBehavior.shouldDeleteRow(text: text) ? "" : text
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, isCompleted, category, completedAt, isDeleted, deletedAt, lastNonemptyText
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        isCompleted = try values.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        category = try values.decodeIfPresent(TodoCategory.self, forKey: .category) ?? .today
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        isDeleted = try values.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        deletedAt = try values.decodeIfPresent(Date.self, forKey: .deletedAt)
        lastNonemptyText = try values.decodeIfPresent(String.self, forKey: .lastNonemptyText)
            ?? (TodoEditingBehavior.shouldDeleteRow(text: text) ? "" : text)
    }
}

enum TodoEditingBehavior {
    static func shouldDeleteRow(text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

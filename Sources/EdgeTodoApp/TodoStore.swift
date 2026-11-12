import Foundation

enum TodoStoreError: Error, Equatable, LocalizedError {
    case emptyText
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "内容不能为空"
        case .notFound:
            return "这条内容已经不存在，可能刚刚被删除"
        }
    }
}

final class TodoStore {
    private let fileURL: URL
    var countdownFileURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("countdowns.json") }
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSRecursiveLock()
    private let now: () -> Date
    var onChange: (() -> Void)?

    init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let value = try container.decode(String.self)
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date"
                )
            }
            return date
        }
        self.decoder = decoder
    }

    func load() throws -> [Todo] {
        try loadArchive().filter { !$0.isDeleted }
    }

    func loadArchive() throws -> [Todo] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        var todos = try decoder.decode([Todo].self, from: data)
        guard Set(todos.map(\.id)).count == todos.count else { throw TodoStoreError.notFound }
        var adopted = false
        for index in todos.indices where todos[index].isCompleted && todos[index].completedAt == nil {
            todos[index].completedAt = now()
            adopted = true
        }
        if adopted {
            try persist(todos)
            return try decoder.decode([Todo].self, from: Data(contentsOf: fileURL))
        }
        return todos
    }

    @discardableResult
    func add(text: String, category: TodoCategory = .today) throws -> Todo {
        lock.lock(); defer { lock.unlock() }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw TodoStoreError.emptyText
        }

        var todos = try loadArchive()
        let todo = Todo(text: trimmedText, createdAt: now(), category: category)
        todos.append(todo)
        try save(todos)
        return todo
    }

    @discardableResult
    func importNote(id: UUID, text: String) throws -> Todo {
        lock.lock(); defer { lock.unlock() }
        var todos = try loadArchive()
        if let existing = todos.first(where: { $0.id == id }) {
            return existing
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { throw TodoStoreError.emptyText }
        let note = Todo(id: id, text: trimmedText, createdAt: now(), category: .notes)
        todos.append(note)
        try save(todos)
        return note
    }

    func save(_ todos: [Todo]) throws {
        lock.lock(); defer { lock.unlock() }
        let existing = try loadArchive()
        let deletedIDs = Set(existing.filter(\.isDeleted).map(\.id))
        var merged = todos.filter { !deletedIDs.contains($0.id) }
        for index in merged.indices {
            if let previous = existing.first(where: { $0.id == merged[index].id }),
               merged[index].text.count < previous.text.count {
                merged[index].lastNonemptyText = previous.lastNonemptyText
            } else if !TodoEditingBehavior.shouldDeleteRow(text: merged[index].text) {
                merged[index].lastNonemptyText = merged[index].text
            } else if let previous = existing.first(where: { $0.id == merged[index].id }) {
                merged[index].lastNonemptyText = previous.archiveText
            }
        }
        merged.append(contentsOf: existing.filter { $0.isDeleted })
        guard Set(merged.map(\.id)).count == merged.count else { throw TodoStoreError.notFound }
        try persist(merged)
    }

    private func persist(_ todos: [Todo]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(todos)
        try data.write(to: fileURL, options: .atomic)
        onChange?()
    }

    func reorderActiveToday(_ orderedIDs: [UUID]) throws {
        lock.lock(); defer { lock.unlock() }
        var all = try loadArchive()
        let positions = all.indices.filter { !all[$0].isDeleted && all[$0].category == .today && !all[$0].isCompleted }
        let current = positions.map { all[$0] }
        guard orderedIDs.count == current.count, Set(orderedIDs) == Set(current.map(\.id)) else { throw TodoStoreError.notFound }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for (position, id) in zip(positions, orderedIDs) { all[position] = byID[id]! }
        try save(all)
    }

    func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var todos = try loadArchive()
        guard let index = todos.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { return }
        todos[index].isDeleted = true
        todos[index].deletedAt = now()
        try save(todos)
    }

    @discardableResult
    func update(id: UUID, text: String) throws -> Todo {
        lock.lock(); defer { lock.unlock() }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw TodoStoreError.emptyText
        }

        var todos = try loadArchive()
        guard let index = todos.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw TodoStoreError.notFound
        }

        todos[index].text = trimmedText
        todos[index].lastNonemptyText = trimmedText
        try save(todos)
        return todos[index]
    }

    @discardableResult
    func updateCompletion(id: UUID, isCompleted: Bool) throws -> Todo {
        lock.lock(); defer { lock.unlock() }
        var todos = try loadArchive()
        guard let index = todos.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw TodoStoreError.notFound
        }

        guard todos[index].category == .today else { return todos[index] }
        if todos[index].isCompleted != isCompleted {
            todos[index].completedAt = isCompleted ? now() : nil
        }
        todos[index].isCompleted = isCompleted
        try save(todos)
        return todos[index]
    }

    @discardableResult
    func saveDraft(
        id: UUID,
        text: String,
        category: TodoCategory = .today,
        allowInsert: Bool = true,
        insertAfter: UUID? = nil
    ) throws -> Todo {
        lock.lock(); defer { lock.unlock() }
        var todos = try loadArchive()
        if let index = todos.firstIndex(where: { $0.id == id }) {
            guard !todos[index].isDeleted else { throw TodoStoreError.notFound }
            todos[index].text = text
            if !TodoEditingBehavior.shouldDeleteRow(text: text) { todos[index].lastNonemptyText = text }
            try save(todos)
            return todos[index]
        }

        guard allowInsert else { throw TodoStoreError.notFound }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TodoStoreError.emptyText
        }
        let todo = Todo(id: id, text: text, createdAt: now(), category: category)
        if let insertAfter, let index = todos.firstIndex(where: { $0.id == insertAfter }) {
            todos.insert(todo, at: index + 1)
        } else {
            todos.append(todo)
        }
        try save(todos)
        return todo
    }

    @discardableResult
    func move(id: UUID, to category: TodoCategory) throws -> Todo {
        lock.lock(); defer { lock.unlock() }
        var todos = try loadArchive()
        guard let index = todos.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            throw TodoStoreError.notFound
        }
        guard todos[index].category != category else { return todos[index] }
        var todo = todos.remove(at: index)
        todo.category = category
        todo.isCompleted = false
        todo.completedAt = nil
        todos.append(todo)
        try save(todos)
        return todo
    }
}

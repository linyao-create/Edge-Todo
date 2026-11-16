import Foundation

enum CompletionPlacement {
    struct Hold {
        let index: Int
        let wasCompleted: Bool
    }

    static func apply(_ rows: [Todo], holds: [UUID: Hold]) -> [Todo] {
        let retained = rows.filter { holds[$0.id] != nil }
            .sorted { (holds[$0.id]?.index ?? 0) < (holds[$1.id]?.index ?? 0) }
        var result = rows.filter { holds[$0.id] == nil }
        for row in retained {
            let index = min(max(0, holds[row.id]?.index ?? result.count), result.count)
            result.insert(row, at: index)
        }
        return result
    }
}

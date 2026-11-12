import Foundation

final class PanelSelectionStore {
    private let defaults: UserDefaults
    private let key = "edgeTodo.lastPanel"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var category: TodoCategory {
        defaults.string(forKey: key).flatMap(TodoCategory.init(rawValue:)) ?? .today
    }

    func isPinned(displayID: String) -> Bool {
        (defaults.stringArray(forKey: "edgeTodo.pinnedDisplays") ?? []).contains(displayID)
    }

    func setPinned(_ pinned: Bool, displayID: String) {
        var ids = Set(defaults.stringArray(forKey: "edgeTodo.pinnedDisplays") ?? [])
        if pinned { ids.insert(displayID) } else { ids.remove(displayID) }
        defaults.set(ids.sorted(), forKey: "edgeTodo.pinnedDisplays")
    }

    func select(_ category: TodoCategory) {
        defaults.set(category.rawValue, forKey: key)
    }
}

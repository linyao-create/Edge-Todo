import AppKit
import CoreGraphics
import SwiftUI

@MainActor
private final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension Notification.Name {
    static let edgeTodoItemsChanged = Notification.Name("EdgeTodo.itemsChanged")
}

enum EdgePanelLayout {
    static let width: CGFloat = 320
    static let height: CGFloat = 380
    static let cornerRadius: CGFloat = 18
    static let horizontalPadding: CGFloat = 17
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 16
    static let headerHeight: CGFloat = 66
    static let spacing: CGFloat = 11
    static let archiveButtonHeight: CGFloat = 32
    static let archiveButtonWidth: CGFloat = 44
    static let collapsedHandleWidth: CGFloat = 14
    static let collapsedHandleHeight: CGFloat = 54
    static let collapsedHandleThickness: CGFloat = 5
}

@MainActor
final class EdgePanelWindowController: NSObject, ObservableObject {
    @Published private(set) var isExpanded = false
    @Published private(set) var isPinned = false
    private var restoringPinnedPanel = false
    @Published private(set) var saveError: String?
    @Published private(set) var todos: [Todo] = []
    @Published private(set) var selectedCategory: TodoCategory
    @Published private(set) var currentDate = Date()
    @Published private(set) var focusedRowID: UUID?
    @Published private(set) var focusRequest = 0
    @Published private(set) var focusAtEndRequest = 0
    @Published private var draftID = UUID()
    private var draftAfterID: UUID?

    private let window: EdgePanel
    private var interaction: EdgeInteractionController!
    private var dateTimer: Timer?
    private var openCountdownMenus: Set<UUID> = []
    private var dragHeldOpen = false
    private var isDisposed = false
    private let store: TodoStore
    private let selectionStore: PanelSelectionStore
    @Published var archiveSync: ArchiveSyncCoordinator?
    let openArchive: () -> Void
    let countdowns: CountdownManager
    private let screen: NSScreen
    private let collapsedSize = CGSize(width: EdgePanelLayout.collapsedHandleWidth, height: 86)
    @Published private(set) var capturedRowID: UUID?
    @Published private(set) var captureScrollRequest = 0

    var storeForRefresh: TodoStore { store }
    var selectionForRefresh: PanelSelectionStore { selectionStore }

    var listViewportHeight: CGFloat {
        let errorSpace: CGFloat = saveError == nil ? 0 : 44
        let stackSpacingCount: CGFloat = saveError == nil ? 1 : 2
        return max(18, expandedSize().height - EdgePanelLayout.topPadding - EdgePanelLayout.bottomPadding
            - EdgePanelLayout.headerHeight
            - EdgePanelLayout.spacing * stackSpacingCount - errorSpace)
    }

    var visibleRows: [Todo] {
        var rows = todos.filter { $0.category == selectedCategory && $0.isVisible(at: currentDate) }
        if selectedCategory == .today { rows = rows.filter { !$0.isCompleted } + rows.filter { $0.isCompleted } }
        if !rows.contains(where: { $0.id == draftID }) {
            let draft = Todo(id: draftID, text: "", category: selectedCategory)
            if selectedCategory == .today {
                rows.insert(draft, at: rows.firstIndex(where: \.isCompleted) ?? rows.endIndex)
            } else if let draftAfterID, let index = rows.firstIndex(where: { $0.id == draftAfterID }) {
                rows.insert(draft, at: index + 1)
            } else {
                rows.append(draft)
            }
        }
        return rows
    }

    init(store: TodoStore, screen: NSScreen, selectionStore: PanelSelectionStore = PanelSelectionStore(),
         archiveSync: ArchiveSyncCoordinator? = nil, countdowns: CountdownManager? = nil,
         openArchive: @escaping () -> Void = {}) {
        self.store = store
        self.countdowns = countdowns ?? CountdownManager(fileURL: store.countdownFileURL)
        self.screen = screen
        self.selectionStore = selectionStore
        self.archiveSync = archiveSync
        self.openArchive = openArchive
        selectedCategory = selectionStore.category
        window = EdgePanel(contentRect: .zero, styleMask: [.borderless],
            backing: .buffered, defer: false)
        super.init()
        refresh()
        interaction = EdgeInteractionController(onStateChange: { [weak self] state in
            self?.setExpanded(state == .expanded)
        })
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: EdgePanelView(controller: self))
        NotificationCenter.default.addObserver(self, selector: #selector(itemsChanged),
            name: .edgeTodoItemsChanged, object: store)
        dateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func dispose() {
        guard !isDisposed else { return }
        commitActiveEditor()
        isDisposed = true
        dateTimer?.invalidate()
        dateTimer = nil
        NotificationCenter.default.removeObserver(self)
        interaction.cancel()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private var displayID: String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    func show() {
        positionWindow(size: collapsedSize)
        window.orderFrontRegardless()
        if let displayID, selectionStore.isPinned(displayID: displayID) {
            isPinned = true
            interaction.setPinned(true)
            restoringPinnedPanel = true
            interaction.reveal()
            restoringPinnedPanel = false
        }
    }

    func togglePinned() {
        isPinned.toggle()
        if let displayID { selectionStore.setPinned(isPinned, displayID: displayID) }
        interaction.setPinned(isPinned)
        if !isPinned && !window.frame.contains(NSEvent.mouseLocation) { interaction.pointerExited() }
    }

    func hide() { window.orderOut(nil) }

    func reveal() {
        guard !isDisposed else { return }
        finishDraft()
        interaction.reveal()
    }

    func revealCapturedNote(id: UUID) {
        guard !isDisposed else { return }
        finishDraft()
        selectCategory(.notes)
        refresh()
        capturedRowID = id
        interaction.reveal()
        // ScrollViewReader is created when the collapsed panel opens. Publish
        // the scroll request on the next turn, after its content is installed.
        Task { @MainActor [weak self] in
            guard let self, !self.isDisposed, self.capturedRowID == id else { return }
            self.captureScrollRequest &+= 1
        }
    }

    func pointerEntered() { interaction.pointerEntered() }
    func pointerExited() { interaction.pointerExited() }
    func countdownMenuVisibilityChanged(_ visible: Bool, for id: UUID) {
        if visible { openCountdownMenus.insert(id) } else { openCountdownMenus.remove(id) }
        let anyOpen = !openCountdownMenus.isEmpty
        interaction.setHeldOpen(anyOpen || dragHeldOpen)
        if !anyOpen && !window.frame.contains(NSEvent.mouseLocation) { interaction.pointerExited() }
    }

    func holdPanelOpen(_ held: Bool) {
        dragHeldOpen = held
        interaction.setHeldOpen(held || !openCountdownMenus.isEmpty)
        if !held && openCountdownMenus.isEmpty && !window.frame.contains(NSEvent.mouseLocation) { interaction.pointerExited() }
    }

    func selectCategory(_ category: TodoCategory) {
        guard category != selectedCategory else { return }
        finishDraft()
        selectedCategory = category
        selectionStore.select(category)
        refresh()
    }

    func beginEditing(todoID: UUID) {
        guard focusedRowID != todoID else { return }
        focusedRowID = todoID
    }

    func endEditing(todoID: UUID) {
        if focusedRowID == todoID { focusedRowID = nil }
    }

    func updateEditingText(todoID: UUID, text: String) {
        let isNewDraft = todoID == draftID && !todos.contains { $0.id == todoID }
        guard isNewDraft || todos.contains(where: { $0.id == todoID && $0.category == selectedCategory }) else { return }
        if isNewDraft && TodoEditingBehavior.shouldDeleteRow(text: text) { return }
        do {
            _ = try store.saveDraft(id: todoID, text: text, category: selectedCategory,
                allowInsert: isNewDraft, insertAfter: draftAfterID)
            didSave()
        } catch TodoStoreError.notFound {
            refresh()
        } catch { report(error, action: "保存") }
    }

    func submitRow(todoID: UUID) {
        guard let row = todos.first(where: { $0.id == todoID }),
              row.category == selectedCategory,
              !TodoEditingBehavior.shouldDeleteRow(text: row.text) else { return }
        draftID = UUID()
        draftAfterID = selectedCategory == .today ? nil : todoID
        requestFocus(draftID)
        resizeIfExpanded()
    }

    func deleteEmptyRow(todoID: UUID) {
        guard let row = visibleRows.first(where: { $0.id == todoID }),
              TodoEditingBehavior.shouldDeleteRow(text: row.text) else { return }
        let rows = visibleRows
        let previousID = rows.firstIndex(where: { $0.id == todoID }).flatMap { index in
            index > 0 ? rows[index - 1].id : nil
        }
        do {
            if todos.contains(where: { $0.id == todoID }) { try store.delete(id: todoID) }
            if draftID == todoID { draftID = UUID(); draftAfterID = nil }
            if draftAfterID == todoID { draftAfterID = previousID }
            didSave()
            requestFocus(previousID ?? draftID)
        } catch { report(error, action: "删除") }
    }

    func reorderActiveToday(_ ids: [UUID]) {
        do { try store.reorderActiveToday(ids); didSave() }
        catch { report(error, action: "保存顺序") }
    }

    func toggleCompletion(todoID: UUID) {
        guard let row = todos.first(where: { $0.id == todoID }), row.category == .today else { return }
        do {
            _ = try store.updateCompletion(id: todoID, isCompleted: !row.isCompleted)
            if !row.isCompleted && draftID == todoID {
                draftID = UUID()
                draftAfterID = nil
            }
            didSave()
        } catch { report(error, action: "更新完成状态") }
    }

    func moveItem(todoID: UUID) {
        commitActiveEditor()
        guard let row = todos.first(where: { $0.id == todoID }), row.category == selectedCategory else { return }
        do {
            _ = try store.move(id: todoID, to: row.category.destination)
            if draftID == todoID { draftID = UUID(); draftAfterID = nil }
            if draftAfterID == todoID { draftAfterID = nil }
            didSave()
            requestFocus(draftID)
        } catch { report(error, action: "移动") }
    }

    func openSavedLink(_ link: SavedLinkNote) {
        if !NSWorkspace.shared.open(link.url) {
            report(CocoaError(.fileReadNoSuchFile), action: "打开网页")
        }
    }

    func deleteSavedLink(todoID: UUID) {
        guard let note = todos.first(where: { $0.id == todoID }),
              SavedLinkNote(text: note.text) != nil else { return }
        do {
            try store.delete(id: todoID)
            if draftAfterID == todoID { draftAfterID = nil }
            didSave()
        } catch { report(error, action: "删除链接") }
    }

    func refresh() {
        do {
            let draftWasSaved = todos.contains { $0.id == draftID }
            todos = try store.load()
            countdowns.retain(Set(todos.filter { $0.category == .today && !$0.isCompleted }.map(\.id)))
            currentDate = Date()
            if draftWasSaved && !todos.contains(where: {
                $0.id == draftID && $0.category == selectedCategory && $0.isVisible(at: currentDate)
            }) {
                draftID = UUID()
                draftAfterID = nil
            }
            saveError = nil
            resizeIfExpanded()
        } catch { report(error, action: "读取") }
    }

    @objc private func itemsChanged() { refresh() }

    private func didSave() {
        refresh()
        NotificationCenter.default.post(name: .edgeTodoItemsChanged, object: store)
    }

    private func finishDraft() {
        commitActiveEditor()
        window.makeFirstResponder(nil)
        // Existing rows (including empty text) are already persisted per character.
        draftID = UUID()
        draftAfterID = nil
        focusedRowID = nil
    }

    private func requestFocus(_ id: UUID, atEnd: Bool = false) {
        focusedRowID = id
        focusRequest &+= 1
        if atEnd { focusAtEndRequest = focusRequest }
    }

    private func setExpanded(_ expanded: Bool) {
        guard !isDisposed else { return }
        if !expanded { finishDraft() }
        isExpanded = expanded
        window.hasShadow = expanded
        if expanded {
            selectedCategory = selectionStore.category
            refresh()
            if restoringPinnedPanel { window.orderFrontRegardless() }
            else { NSApp.activate(ignoringOtherApps: true); window.makeKey() }
        } else {
            positionWindow(size: collapsedSize)
            window.orderFrontRegardless()
        }
    }

    private func report(_ error: Error, action: String) {
        saveError = "\(action)失败：\(error.localizedDescription)"
        resizeIfExpanded()
        NSLog("Edge Todo %@ failed: %@", action, String(describing: error))
    }

    private func commitActiveEditor() {
        (window.firstResponder as? InlineEditorTextView)?.unmarkText()
    }

    private func resizeIfExpanded() {
        if isExpanded { positionWindow(size: expandedSize()) }
    }

    private func positionWindow(size: CGSize) {
        let frame = screen.visibleFrame
        window.setFrame(CGRect(x: frame.minX, y: frame.midY - size.height / 2,
            width: size.width, height: size.height), display: true, animate: false)
    }

    private func expandedSize() -> CGSize {
        CGSize(width: EdgePanelLayout.width,
            height: min(EdgePanelLayout.height, max(120, screen.visibleFrame.height - 32)))
    }
}

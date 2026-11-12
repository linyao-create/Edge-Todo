import SwiftUI
import AppKit

public enum AppIdentity {
    public static let name = "Edge Todo"
}

@main
struct EdgeTodoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandMenu("待办") {
                    Button("显示待办面板") {
                        NotificationCenter.default.post(name: .edgeTodoShowPanelRequest, object: nil)
                    }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                }
            }
    }
}

private extension Notification.Name {
    static let edgeTodoShowPanelRequest = Notification.Name("EdgeTodo.showPanel")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelControllers: [EdgePanelWindowController] = []
    private var todoStore: TodoStore?
    private var countdownManager: CountdownManager?
    private var selectionStore = PanelSelectionStore()
    private var archiveSync: ArchiveSyncCoordinator?
    private var dataDirectory: URL?
    private var browserCaptureReceiver: BrowserCaptureReceiver?
    private var pendingBrowserURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep Edge Todo as a lightweight menu-bar-less panel app. The panel
        // explicitly activates the app only when the user enters it to type.
        NSApp.setActivationPolicy(.accessory)

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        var dataDirectory = applicationSupport
            .appendingPathComponent("EdgeTodo", isDirectory: true)
        if let directory = ProcessInfo.processInfo.environment["EDGE_TODO_DATA_DIRECTORY"] {
            dataDirectory = URL(fileURLWithPath: directory, isDirectory: true)
            if let defaults = UserDefaults(suiteName: "EdgeTodo.debug.\(dataDirectory.lastPathComponent)") {
                selectionStore = PanelSelectionStore(defaults: defaults)
            }
        }
        self.dataDirectory = dataDirectory
        let fileURL = dataDirectory.appendingPathComponent("todos.json")

        let store = TodoStore(fileURL: fileURL)
        todoStore = store
        countdownManager = CountdownManager(fileURL: dataDirectory.appendingPathComponent("countdowns.json"))
        browserCaptureReceiver = BrowserCaptureReceiver(store: store)
        updateArchiveSync()
        rebuildPanels(store: store, selectionStore: selectionStore)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showPanelRequested),
            name: .edgeTodoShowPanelRequest,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let queuedURLs = pendingBrowserURLs
        pendingBrowserURLs.removeAll()
        application(NSApp, open: queuedURLs)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let receiver = browserCaptureReceiver, let store = todoStore else {
            pendingBrowserURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            if BrowserPanelRevealRequest.matches(url) {
                revealPanelAtPointer()
                continue
            }
            do {
                let note = try receiver.receive(url)
                NotificationCenter.default.post(name: Notification.Name("EdgeTodo.itemsChanged"), object: store)
                // Reveal on the display where the user clicked, without opening
                // panels on every monitor or starting a text-editing session.
                revealPanelAtPointer(noteID: note.id)
            } catch {
                let alert = NSAlert()
                alert.messageText = "未能存到随记"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private func revealPanelAtPointer(noteID: UUID? = nil) {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let index = screen.flatMap { NSScreen.screens.firstIndex(of: $0) } ?? 0
        guard panelControllers.indices.contains(index) else { return }
        if let noteID {
            panelControllers[index].revealCapturedNote(id: noteID)
        } else {
            panelControllers[index].reveal()
        }
    }

    @objc private func screenParametersDidChange() {
        guard let store = panelControllers.first.map({ $0.storeForRefresh }) else { return }
        guard let selectionStore = panelControllers.first?.selectionForRefresh else { return }
        rebuildPanels(store: store, selectionStore: selectionStore)
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelControllers.forEach { $0.dispose() }
        archiveSync?.stop()
    }

    @objc private func showPanelRequested() {
        revealPanelAtPointer()
    }

    private func updateArchiveSync() {
        archiveSync?.stop()
        archiveSync = nil
        defer { panelControllers.forEach { $0.archiveSync = archiveSync } }
        guard let dataDirectory, let todoStore,
              let settings = try? ArchiveSettings.load(from: dataDirectory),
              !settings.accountID.isEmpty,
              let target = try? ArchiveDestination(table: settings.table, document: settings.document) else { return }

        do {
            let connection = try ArchiveConnection(settings: settings)
            let table = FeishuDailyArchiveTransport(target: target, connection: connection)
            let document = FeishuDailyDocumentTransport(documentID: target.documentID, connection: connection)
            let sync = ArchiveSyncCoordinator(store: todoStore,
                metadataURL: settings.metadataURL(in: dataDirectory, target: target),
                transport: table, documentTransport: document, validateAccount: {
                    guard try await connection.accountID() == settings.accountID else {
                        throw ArchiveSettingsError.changedAccount
                    }
                })
            archiveSync = sync
            sync.start()
        } catch {
            // Setup remains available when a previously installed CLI has moved.
        }
    }

    private func openArchive() {
        if let dataDirectory, let settings = try? ArchiveSettings.load(from: dataDirectory),
           let destination = try? ArchiveDestination(table: settings.table, document: settings.document) {
            NSWorkspace.shared.open(destination.tableURL)
        } else {
            let alert = NSAlert()
            alert.messageText = "连接飞书"
            alert.informativeText = "请告诉你的 AI：帮我连接 Edge Todo 和我的飞书。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func rebuildPanels(store: TodoStore, selectionStore: PanelSelectionStore) {
        panelControllers.forEach {
            $0.dispose()
            $0.hide()
        }
        guard let countdownManager else { return }
        panelControllers = NSScreen.screens.map { screen in
            let controller = EdgePanelWindowController(store: store, screen: screen,
                selectionStore: selectionStore, archiveSync: archiveSync, countdowns: countdownManager,
                openArchive: { [weak self] in self?.openArchive() })
            controller.show()
            return controller
        }
    }
}

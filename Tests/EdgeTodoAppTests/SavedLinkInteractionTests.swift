import AppKit
import SwiftUI
import XCTest
@testable import EdgeTodoApp

@MainActor
final class SavedLinkInteractionTests: XCTestCase {
    private func makeController() throws -> (EdgePanelWindowController, TodoStore, () -> Void) {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        let suite = "SavedLinkInteractionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = EdgePanelWindowController(store: store, screen: screen,
            selectionStore: PanelSelectionStore(defaults: defaults))
        return (controller, store, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    func testCursorStateBalancesRepeatedHoverAndRemoval() {
        let previous = NSCursor.current
        NSCursor.arrow.push()
        defer {
            NSCursor.pop()
            previous.set()
        }

        let state = PointingHandCursorState()
        state.setHovered(true)
        state.setHovered(true)
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(NSCursor.current === NSCursor.pointingHand)

        state.disappear()
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
    }

    func testSavedLinkMenuListsPrimaryAndSecondaryActions() {
        XCTAssertEqual(SavedLinkMenuAction.allCases.map(\.rawValue), [
            "打开网页", "删除链接"
        ])
    }

    func testDeletingSavedLinkRemovesItFromPanelButPreservesFullArchiveText() throws {
        let (controller, store, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let address = "https://example.com/a?token=a%2Fb#part"
        let original = "Example\n\(address)"
        let note = try store.importNote(id: UUID(), text: original)
        controller.selectCategory(.notes)
        XCTAssertTrue(controller.visibleRows.contains { $0.id == note.id })

        controller.deleteSavedLink(todoID: note.id)

        XCTAssertFalse(controller.visibleRows.contains { $0.id == note.id })
        XCTAssertTrue(try store.load().isEmpty)
        let retained = try XCTUnwrap(store.loadArchive().first { $0.id == note.id })
        XCTAssertTrue(retained.isDeleted)
        XCTAssertEqual(retained.archiveText, original)
    }

    func testDeleteSavedLinkIgnoresOrdinaryTextNote() throws {
        let (controller, store, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let note = try store.importNote(id: UUID(), text: "普通随记")
        controller.selectCategory(.notes)

        controller.deleteSavedLink(todoID: note.id)

        XCTAssertEqual(try store.load().map(\.id), [note.id])
    }

    func testMovedLinkCanStillBeDeleted() throws {
        let (controller, store, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let note = try store.importNote(id: UUID(), text: "Example\nhttps://example.com/page")
        controller.selectCategory(.notes)
        controller.moveItem(todoID: note.id)
        controller.selectCategory(.today)
        XCTAssertTrue(controller.visibleRows.contains { $0.id == note.id })

        controller.deleteSavedLink(todoID: note.id)

        XCTAssertFalse(controller.visibleRows.contains { $0.id == note.id })
        XCTAssertEqual(try store.loadArchive().first?.archiveText, note.text)
    }

    func testMovedLinkUsesLinkCardInsteadOfTextEditor() async throws {
        let (controller, store, cleanup) = try makeController()
        defer { controller.dispose(); cleanup() }
        let note = try store.importNote(id: UUID(), text: "Example\nhttps://example.com/page")
        controller.selectCategory(.notes)
        controller.moveItem(todoID: note.id)
        controller.selectCategory(.today)
        controller.pointerEntered()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(controller.isExpanded)
        XCTAssertTrue(controller.visibleRows.contains { $0.id == note.id })

        let host = try XCTUnwrap(NSApp.windows.compactMap {
            $0.contentView as? NSHostingView<EdgePanelView>
        }.first { $0.rootView.controller === controller })
        host.layoutSubtreeIfNeeded()
        func editors(in view: NSView) -> [InlineEditorTextView] {
            if let editor = view as? InlineEditorTextView { return [editor] }
            return view.subviews.flatMap { editors(in: $0) }
        }
        XCTAssertFalse(editors(in: host).contains { $0.string == note.text })
    }

}

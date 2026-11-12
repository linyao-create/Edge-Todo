import AppKit
import SwiftUI
import XCTest
@testable import EdgeTodoApp

@MainActor
final class EditorIntegrationTests: XCTestCase {
    func testHoveringAnotherRowCommitsCompositionWithoutMovingEditingFocus() async throws {
        _ = NSApplication.shared
        let first = InlineEditorTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 18))
        let second = InlineEditorTextView(frame: NSRect(x: 0, y: 30, width: 200, height: 18))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        defer { window.close() }
        var savedText: String?
        first.onTextChange = { savedText = $0 }
        window.makeFirstResponder(first)
        first.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        let hover = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        second.mouseEntered(with: hover)
        XCTAssertFalse(window.firstResponder === second, "Hovering must not place an insertion caret in the next row")
        XCTAssertTrue(window.firstResponder === first, "Mouse movement alone should not move the editing caret")
        XCTAssertFalse(first.hasMarkedText())
        XCTAssertEqual(savedText, "拼")
        second.unmarkText() // Only the clicked row can own a new composition.
        XCTAssertEqual(savedText, "拼")
    }

    func testExternalSnapshotClearsUndoRangesBeforeReplacingText() async throws {
        _ = NSApplication.shared
        let editor = InlineEditorTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 18))
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        editor.apply(text: "a", isCompleted: false, focusRequest: 1)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.undoManager?.canUndo ?? false)
        editor.apply(text: "", isCompleted: false, focusRequest: 1)
        // Calling stale undo here used to throw an uncaught native NSRangeException.
        XCTAssertFalse(editor.undoManager?.canUndo ?? true)
        editor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(editor.undoManager?.canUndo ?? false)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "")
    }

    func testSwitchAndCollapseCommitChineseCompositionBeforeRemovingEditor() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EdgeTodoIMEIntegration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        let controller = EdgePanelWindowController(store: store, screen: try XCTUnwrap(NSScreen.screens.first),
            selectionStore: PanelSelectionStore(defaults: defaults))
        defer {
            controller.dispose()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        controller.pointerEntered()
        try await Task.sleep(for: .milliseconds(400))
        let panel = try XCTUnwrap(NSApp.windows.first {
            ($0.contentView as? NSHostingView<EdgePanelView>)?.rootView.controller === controller
        })
        let root = try XCTUnwrap(panel.contentView)
        root.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(descendants(root).compactMap { $0 as? InlineEditorTextView }.first)
        panel.makeFirstResponder(editor)
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        controller.selectCategory(.notes)
        XCTAssertEqual(try store.load().first?.text, "拼")
        XCTAssertEqual(try store.load().first?.category, .today)
        try await Task.sleep(for: .milliseconds(100))
        root.layoutSubtreeIfNeeded()
        let noteEditor = try XCTUnwrap(descendants(root).compactMap { $0 as? InlineEditorTextView }.first)
        panel.makeFirstResponder(noteEditor)
        noteEditor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        noteEditor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.pointerExited()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(controller.isExpanded)
        XCTAssertEqual(try store.load().first { $0.category == .notes }?.text, "a中")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

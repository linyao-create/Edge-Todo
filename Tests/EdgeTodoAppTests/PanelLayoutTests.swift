import AppKit
import SwiftUI
import XCTest
@testable import EdgeTodoApp

@MainActor
final class PanelLayoutTests: XCTestCase {
    func testCollapsedHandleUsesSoftCapsuleDesignDimensions() {
        XCTAssertEqual(CollapsedHandleStyle.restingWidth, 7)
        XCTAssertEqual(CollapsedHandleStyle.restingHeight, 52)
        XCTAssertEqual(CollapsedHandleStyle.hoverWidth, CollapsedHandleStyle.restingWidth)
        XCTAssertEqual(CollapsedHandleStyle.hoverHeight, CollapsedHandleStyle.restingHeight)
        XCTAssertEqual(CollapsedHandleStyle.trailingInset, 0)
    }

    func testCollapsedPanelLeavesAVisibleAndUsableEdgeHandle() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EdgeTodoCollapsedHandleTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = EdgePanelWindowController(store: TodoStore(fileURL: directory.appendingPathComponent("todos.json")),
            screen: screen, selectionStore: PanelSelectionStore(defaults: defaults))
        defer {
            controller.dispose()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.first {
            ($0.contentView as? NSHostingView<EdgePanelView>)?.rootView.controller === controller
        })
        XCTAssertEqual(panel.frame.width, EdgePanelLayout.collapsedHandleWidth)
        XCTAssertEqual(panel.frame.height, 86)
        XCTAssertFalse(panel.hasShadow, "The collapsed handle should not cast a rectangular window shadow")
        XCTAssertGreaterThanOrEqual(EdgePanelLayout.collapsedHandleWidth, 14)
    }

    func testCategoryButtonsHaveLargerClickAreaAndSwitchWithoutMovingPanel() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EdgeTodoTabTargetTests.\(UUID())"
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
        XCTAssertTrue(panel.hasShadow, "The expanded panel should retain its soft window shadow")
        let root = try XCTUnwrap(panel.contentView)
        root.layoutSubtreeIfNeeded()
        XCTAssertFalse(panel.firstResponder is InlineEditorTextView,
            "Opening the panel should not display a text caret before the user clicks a row")
        // Native focus targets expose the real SwiftUI button layout, even when
        // this test runner does not populate the system accessibility tree.
        let allButtons = descendants(of: root).filter {
            String(describing: type(of: $0)) == "_FocusRingView"
        }.map { $0.convert($0.bounds, to: root) }
        let headerButtons = allButtons.filter { $0.minY >= 17 && $0.minY <= 28 }
            .sorted { $0.minX < $1.minX }
        XCTAssertEqual(headerButtons.count, 4)
        XCTAssertTrue(headerButtons.contains { abs($0.width - 30) < 1 && abs($0.height - 32) < 1 },
            "The pin button remains available")
        let today = try XCTUnwrap(headerButtons.first)
        let notes = try XCTUnwrap(headerButtons.dropFirst().first)
        for button in [today, notes] {
            XCTAssertEqual(button.width, 76, accuracy: 1)
            XCTAssertEqual(button.height, 26, accuracy: 1)
        }
        XCTAssertFalse(allButtons.contains { abs($0.width - 52) < 1 && abs($0.height - 32) < 1 },
            "The panel should not expose a microphone button")
        let archiveButton = try XCTUnwrap(headerButtons.last)
        XCTAssertEqual(archiveButton.width, 44, accuracy: 1)
        XCTAssertEqual(archiveButton.height, 32, accuracy: 1)
        XCTAssertLessThanOrEqual(archiveButton.maxX, root.bounds.maxX - 17 + 1)
        XCTAssertEqual(controller.selectedCategory, .today)
        let frame = panel.frame
        controller.selectCategory(.notes)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.selectedCategory, .notes)
        XCTAssertEqual(panel.frame, frame)
        XCTAssertFalse(panel.firstResponder is InlineEditorTextView,
            "Switching categories should not focus a row before the user clicks it")
        root.layoutSubtreeIfNeeded()
        let noteButtons = descendants(of: root).filter {
            String(describing: type(of: $0)) == "_FocusRingView"
        }.map { $0.convert($0.bounds, to: root) }.filter { $0.minY >= 17 && $0.minY <= 28 }
        XCTAssertEqual(noteButtons.count, 4, "The pin and archive controls remain available in quick notes")
        controller.selectCategory(.today)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.selectedCategory, .today)
        XCTAssertEqual(panel.frame, frame)
    }

    func testBothTabsKeepSameTallerWindowAndScrollBelowHeaderRegardlessOfContent() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EdgeTodoFixedLayoutTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        let controller = EdgePanelWindowController(store: store, screen: screen,
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
        let fixedHeight = min(380, max(120, screen.visibleFrame.height - 32))
        XCTAssertEqual(panel.frame.height, fixedHeight, accuracy: 1)
        let initialFrame = panel.frame
        controller.selectCategory(.notes)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(panel.frame, initialFrame)
        let root = try XCTUnwrap(panel.contentView)
        root.layoutSubtreeIfNeeded()
        let emptyList = try XCTUnwrap(descendants(of: root).compactMap { $0 as? NSScrollView }.first)
        let emptyViewport = emptyList.convert(emptyList.bounds, to: root)
        let expectedListHeight = max(18, fixedHeight - 34 - 66 - EdgePanelLayout.spacing)
        XCTAssertEqual(emptyViewport.height, expectedListHeight, accuracy: 1)
        if root.isFlipped {
            XCTAssertGreaterThanOrEqual(emptyViewport.minY, root.bounds.minY + 17 + 66 + EdgePanelLayout.spacing - 1)
        } else {
            XCTAssertLessThanOrEqual(emptyViewport.maxY, root.bounds.maxY - 17 - 66 - EdgePanelLayout.spacing + 1)
        }
        try store.save((0..<30).map { Todo(text: "第\($0)条较长随记内容，需要换行显示而不是挤到标题区", category: .notes) })
        controller.refresh()
        try await Task.sleep(for: .milliseconds(100))
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame, initialFrame)
        let scroll = try XCTUnwrap(descendants(of: root).compactMap { $0 as? NSScrollView }.first)
        XCTAssertTrue(scroll.verticalScroller is SlimOverlayScroller,
            "The list must use its fixed-appearance overlay scroller")
        XCTAssertEqual(scroll.convert(scroll.bounds, to: root), emptyViewport)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentView.bounds.height)
        let editors = descendants(of: scroll).compactMap { $0 as? InlineEditorTextView }
        XCTAssertTrue(editors.contains { !$0.string.isEmpty })
        for editor in editors where !editor.string.isEmpty {
            let textRect = editor.convert(editor.bounds, to: root)
            XCTAssertLessThanOrEqual(textRect.maxX + 9 + 44, emptyViewport.maxX - 20 + 1,
                "Reserve a right gutter for the scrollbar after the move button")
        }
        if let scroller = scroll.verticalScroller {
            let scrollerRect = scroller.convert(scroller.bounds, to: root)
            XCTAssertLessThanOrEqual(scrollerRect.maxY, emptyViewport.maxY + 1)
            XCTAssertGreaterThanOrEqual(scrollerRect.minY, emptyViewport.minY - 1)
        }
        controller.selectCategory(.today)
        try await Task.sleep(for: .milliseconds(100))
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame, initialFrame)
        let todayScroll = try XCTUnwrap(descendants(of: root).compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual(todayScroll.convert(todayScroll.bounds, to: root), emptyViewport)
    }

    func testSavedLinkDeleteSitsBesideTitleAndMoveAlignsWithTextRow() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EdgeTodoLinkLayoutTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        _ = try store.importNote(id: UUID(), text: "how I use NFC tags around my apartment\nhttps://youtube.com/watch?v=example")
        _ = try store.add(text: "普通文字随记", category: .notes)
        let controller = EdgePanelWindowController(store: store, screen: screen,
            selectionStore: PanelSelectionStore(defaults: defaults))
        defer {
            controller.dispose()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        controller.selectCategory(.notes)
        controller.pointerEntered()
        try await Task.sleep(for: .milliseconds(400))
        let panel = try XCTUnwrap(NSApp.windows.first {
            ($0.contentView as? NSHostingView<EdgePanelView>)?.rootView.controller === controller
        })
        let root = try XCTUnwrap(panel.contentView)
        root.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(of: root).compactMap { $0 as? NSScrollView }.first)
        let moveButtons = descendants(of: scroll).compactMap { $0 as? MoveActionNativeButton }
        XCTAssertEqual(moveButtons.count, 2)
        XCTAssertTrue(moveButtons.allSatisfy { !$0.actionIsVisible },
            "Move actions should stay hidden until their row is hovered")
        let moveFrames = moveButtons.map { $0.convert($0.bounds, to: root) }
        XCTAssertEqual(moveFrames.count, 2)
        let move = try XCTUnwrap(moveFrames.first)
        XCTAssertEqual(move.minX, try XCTUnwrap(moveFrames.last).minX, accuracy: 1,
            "Move should keep the same right-edge position for links and text rows")
        let focusFrames = descendants(of: scroll).filter {
            String(describing: type(of: $0)) == "_FocusRingView"
        }.map { $0.convert($0.bounds, to: root) }
        let title = try XCTUnwrap(focusFrames.first { $0.width > 100 && $0.minX < move.minX })
        XCTAssertGreaterThan(title.height, 50,
            "Long link titles should use a third line instead of being cut off by the delete button")
        let deleteActions = focusFrames.filter {
            $0.width >= 20 && $0.width <= 32 && $0.height >= 20 && $0.height <= 28
                && $0.minX < move.minX
                && $0.minY < title.maxY && $0.maxY > title.minY
        }
        XCTAssertEqual(deleteActions.count, 1, "A link should have one delete button beside its title")
        let delete = try XCTUnwrap(deleteActions.first)
        XCTAssertGreaterThan(delete.minX, title.midX)
        XCTAssertLessThanOrEqual(delete.maxX + 8, move.minX,
            "Delete should remain separate from the move button")
        let textEditor = try XCTUnwrap(descendants(of: scroll).compactMap { $0 as? InlineEditorTextView }.first)
        let textFrame = textEditor.convert(textEditor.bounds, to: root)
        let gapBelowLink = root.isFlipped ? textFrame.minY - title.maxY : title.minY - textFrame.maxY
        XCTAssertLessThanOrEqual(gapBelowLink, 24,
            "Removing the separate edit row should leave only normal list spacing below a link")
    }

    func testOverlayScrollerThumbWidthDoesNotGrowWithHoveredTrack() {
        let knob = NSRect(x: 0, y: 30, width: 14, height: 80)
        let narrowTrack = SlimOverlayScroller.visualThumbRect(for: knob,
            in: NSRect(x: 0, y: 0, width: 6, height: 200))
        let expandedTrack = SlimOverlayScroller.visualThumbRect(for: knob,
            in: NSRect(x: 0, y: 0, width: 16, height: 200))

        XCTAssertEqual(narrowTrack.width, SlimOverlayScroller.visualThumbWidth)
        XCTAssertEqual(expandedTrack.width, SlimOverlayScroller.visualThumbWidth)
        XCTAssertEqual(narrowTrack.maxX, 5, accuracy: 0.01)
        XCTAssertEqual(expandedTrack.maxX, 15, accuracy: 0.01)
    }

    func testLongRowsWrapInsidePanelAndHeaderDoesNotConsumeListSpace() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        let suite = "EdgeTodoLayoutTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let longText = String(repeating: "较长的待办内容需要自动换行 ", count: 8)
            .trimmingCharacters(in: .whitespaces)
        _ = try store.add(text: longText)
        _ = try store.add(text: "简短待办")
        let controller = EdgePanelWindowController(store: store, screen: screen,
            selectionStore: PanelSelectionStore(defaults: defaults))
        defer {
            controller.dispose()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        controller.pointerEntered()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(controller.isExpanded)
        let host = NSHostingView(rootView: EdgePanelView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 380)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let editors = descendants(of: host).compactMap { $0 as? InlineEditorTextView }
        let longEditor = try XCTUnwrap(editors.first { $0.string == longText })
        XCTAssertGreaterThan(longEditor.frame.height, 18)
        XCTAssertGreaterThan(longEditor.frame.width, 150)
        XCTAssertLessThanOrEqual(longEditor.frame.width, 213)
        XCTAssertGreaterThanOrEqual(longEditor.frame.height, longEditor.intrinsicContentSize.height - 1)
        XCTAssertEqual(editors.count, 3)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

}

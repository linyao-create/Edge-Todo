import AppKit
import SwiftUI
import XCTest
@testable import EdgeTodoApp

@MainActor
final class InlineTextEditorTests: XCTestCase {
    private func editor(_ text: String = "") -> InlineEditorTextView {
        _ = NSApplication.shared
        let view = InlineEditorTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 30))
        view.apply(text: text, isCompleted: false, focusRequest: 0)
        return view
    }

    private func window(containing view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    func testTodayPlaceholderHidesDuringChineseCompositionAndReturnsWhenEmpty() async {
        let view = editor("")
        view.emptyPlaceholder = "写下一件待办…"
        XCTAssertTrue(view.shouldDrawEmptyPlaceholder)
        view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(view.shouldDrawEmptyPlaceholder)
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: view.markedRange())
        XCTAssertTrue(view.shouldDrawEmptyPlaceholder)
    }

    func testExactSwiftUIInterfaceCompiles() async {
        _ = InlineTextEditor(text: "hello", isCompleted: false, focusRequest: 0, focusAtEndRequest: 0,
                             onBeginEditing: {}, onTextChange: { _ in },
                             onSubmit: {}, onEmptyDelete: {})
    }

    func testInitialZeroDoesNotStealFocus() async {
        let view = editor("hello")
        let host = window(containing: view)
        defer { host.close() }
        XCTAssertFalse(host.firstResponder === view)
    }

    func testInitialPositiveFocusRequestWaitsForWindowAndPreservesCaret() async {
        let view = editor("hello")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.apply(text: "hello", isCompleted: false, focusRequest: 1)
        let host = window(containing: view)
        defer { host.close() }
        XCTAssertTrue(host.firstResponder === view)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testFocusAtEndRequestPlacesCaretAfterUpdatedText() async {
        let view = editor("原有内容后续文字")
        let host = window(containing: view)
        defer { host.close() }

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.apply(text: "原有内容后续文字", isCompleted: false,
                   focusRequest: 1, focusAtEndRequest: 1)

        XCTAssertTrue(host.firstResponder === view)
        XCTAssertEqual(view.selectedRange(), NSRange(location: (view.string as NSString).length, length: 0))
    }

    func testBackspaceWorksImmediatelyAfterFocusAtEndRequest() async {
        let view = editor("原有内容后续文字")
        let host = window(containing: view)
        defer { host.close() }
        var changes: [String] = []
        view.onTextChange = { changes.append($0) }
        view.onBeginEditing = { view.setSelectedRange(NSRange(location: 0, length: 0)) }

        view.apply(text: "原有内容后续文字", isCompleted: false,
                   focusRequest: 1, focusAtEndRequest: 1)
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(view.string, "原有内容后续文")
        XCTAssertEqual(changes, ["原有内容后续文"])
        XCTAssertTrue(host.firstResponder === view)
    }

    func testMacBackspaceKeyEventDeletesAtRestoredCaret() async {
        let view = editor("原有内容后续文字")
        let host = window(containing: view)
        defer { host.close() }
        view.apply(text: "原有内容后续文字", isCompleted: false,
                   focusRequest: 1, focusAtEndRequest: 1)
        let event = try! XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: host.windowNumber, context: nil, characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))

        view.keyDown(with: event)

        XCTAssertEqual(view.string, "原有内容后续文")
    }

    func testChangedPositiveFocusRequestFocusesOnceAndZeroDoesNotFocus() async {
        let view = editor("hello")
        let host = window(containing: view)
        defer { host.close() }
        view.apply(text: "hello", isCompleted: false, focusRequest: 2)
        XCTAssertTrue(host.firstResponder === view)
        host.makeFirstResponder(nil)
        view.apply(text: "hello", isCompleted: false, focusRequest: 2)
        XCTAssertFalse(host.firstResponder === view)
        view.apply(text: "hello", isCompleted: false, focusRequest: 0)
        XCTAssertFalse(host.firstResponder === view)
        view.apply(text: "hello", isCompleted: false, focusRequest: 3)
        XCTAssertTrue(host.firstResponder === view)
    }

    func testZeroCancelsPendingFocusBeforeAttachment() async {
        let view = editor("hello")
        view.apply(text: "hello", isCompleted: false, focusRequest: 1)
        view.apply(text: "hello", isCompleted: false, focusRequest: 0)
        let host = window(containing: view)
        defer { host.close() }
        XCTAssertFalse(host.firstResponder === view)
    }

    func testNonTargetRowCannotStealFocusBackFromTargetRow() async {
        let first = editor("first")
        let second = editor("second")
        let host = window(containing: first)
        defer { host.close() }
        host.contentView?.addSubview(second)
        first.apply(text: "first", isCompleted: false, focusRequest: 1)
        second.apply(text: "second", isCompleted: false, focusRequest: 2)
        first.apply(text: "first", isCompleted: false, focusRequest: 0)
        XCTAssertTrue(host.firstResponder === second)
    }

    func testHoverDoesNotFocusEditorOrShowInsertionPoint() async {
        let view = editor("hello")
        let host = window(containing: view)
        defer { host.close() }
        view.setSelectedRange(NSRange(location: 3, length: 0))
        var begins = 0
        view.onBeginEditing = { begins += 1 }
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        view.mouseEntered(with: event)
        view.mouseEntered(with: event)
        XCTAssertFalse(host.firstResponder === view)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(begins, 0)
    }

    func testDeletingLastCharacterPersistsEmptyBeforeNextDeleteRemovesRow() async {
        let view = editor("字")
        var changes: [String] = []
        var deletes = 0
        view.onTextChange = { changes.append($0) }
        view.onEmptyDelete = { deletes += 1 }
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(changes, [""])
        XCTAssertEqual(deletes, 0)
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(deletes, 1)
    }

    func testSelectedCharactersAndWhitespaceUseOrdinaryDeletion() async {
        let view = editor("hello")
        var deletes = 0
        view.onEmptyDelete = { deletes += 1 }
        view.setSelectedRange(NSRange(location: 1, length: 3))
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(view.string, "ho")
        view.apply(text: " ", isCompleted: false, focusRequest: 0)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(deletes, 0)
    }

    func testForwardDeleteOnAlreadyEmptyRowDeletesRow() async {
        let view = editor()
        var deletes = 0
        view.onEmptyDelete = { deletes += 1 }
        view.doCommand(by: #selector(NSResponder.deleteForward(_:)))
        XCTAssertEqual(deletes, 1)
    }

    func testForwardDeleteOnNonemptyRowUsesNativeDeletion() async {
        let view = editor("ab")
        var changes: [String] = []
        var deletes = 0
        view.onTextChange = { changes.append($0) }
        view.onEmptyDelete = { deletes += 1 }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.doCommand(by: #selector(NSResponder.deleteForward(_:)))
        XCTAssertEqual(view.string, "b")
        XCTAssertEqual(changes, ["b"])
        XCTAssertEqual(deletes, 0)
    }

    func testReturnSubmitsWithoutInsertingNewline() async {
        let view = editor("hello")
        var submits = 0
        view.onSubmit = { submits += 1 }
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submits, 1)
        XCTAssertEqual(view.string, "hello")
    }

    func testMarkedReturnIsConsumedAndDeleteIsPassedToNativeInputMethod() async {
        let view = editor()
        var submits = 0
        var deletes = 0
        view.onSubmit = { submits += 1 }
        view.onEmptyDelete = { deletes += 1 }
        view.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertTrue(view.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(view.textView(view, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(submits, 0)
        XCTAssertEqual(deletes, 0)
        XCTAssertTrue(view.hasMarkedText())
    }

    func testCompositionIsNotPersistedOrOverwrittenAndCommitEmitsOnce() async {
        let view = editor("a")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        var changes: [String] = []
        view.onTextChange = { changes.append($0) }
        view.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        view.apply(text: "a", isCompleted: true, focusRequest: 0)
        XCTAssertEqual(view.string, "apin")
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(changes, [])
        view.insertText("拼", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(changes, ["a拼"])
    }

    func testUnmarkCommitsCompositionOnce() async {
        let view = editor()
        var changes: [String] = []
        view.onTextChange = { changes.append($0) }
        view.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        XCTAssertEqual(changes, ["拼"])
    }

    func testProgrammaticUpdatesPreserveSelectionAndDoNotEmitUserChanges() async {
        let view = editor("hello")
        var changes: [String] = []
        view.onTextChange = { changes.append($0) }
        view.setSelectedRange(NSRange(location: 2, length: 2))
        view.apply(text: "hello world", isCompleted: true, focusRequest: 0)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 2))
        XCTAssertEqual(changes, [])
        view.apply(text: "h", isCompleted: false, focusRequest: 0)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testParentEchoOfEachCommittedCharacterKeepsCaretAndEmitsOnce() async {
        let view = editor("ab")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        var changes: [String] = []
        view.onTextChange = { text in
            changes.append(text)
            view.apply(text: text, isCompleted: false, focusRequest: 0)
        }
        view.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(changes, ["a中b"])
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
        view.insertText("文", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(changes, ["a中b", "a中文b"])
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
    }

    func testNativeDeleteRemovesWholeComposedCharacter() async {
        let view = editor("👨‍👩‍👧‍👦")
        var changes: [String] = []
        var deletes = 0
        view.onTextChange = { changes.append($0) }
        view.onEmptyDelete = { deletes += 1 }
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(view.string, "")
        XCTAssertEqual(changes, [""])
        XCTAssertEqual(deletes, 0)
    }

    func testStyleOnlyUpdatesPreserveCaretAndNativeEditingAttributes() async {
        let view = editor("hello")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.apply(text: "hello", isCompleted: true, focusRequest: 0)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertEqual(view.textStorage?.attribute(.strikethroughStyle, at: 0,
                                                  effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        view.apply(text: "hello", isCompleted: false, focusRequest: 0)
        XCTAssertNil(view.textStorage?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
    }

    func testHeightWrapsUnbrokenTextAtCurrentWidthWithoutVerticalScroll() async {
        let view = editor(String(repeating: "W", count: 300))
        view.setFrameSize(NSSize(width: 180, height: 18))
        let wideHeight = view.intrinsicContentSize.height
        view.setFrameSize(NSSize(width: 80, height: 18))
        let narrowHeight = view.intrinsicContentSize.height
        XCTAssertGreaterThan(wideHeight, 18)
        XCTAssertGreaterThan(narrowHeight, wideHeight)
        XCTAssertEqual(view.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertNil(view.enclosingScrollView)
        XCTAssertFalse(view.isHorizontallyResizable)
        XCTAssertEqual(view.textContainer?.containerSize.width, 80)
        guard let layoutManager = view.layoutManager, let container = view.textContainer else {
            return XCTFail("The editor must have a native text layout stack")
        }
        let used = layoutManager.usedRect(for: container)
        XCTAssertLessThanOrEqual(used.maxX, 80.5)
        XCTAssertGreaterThanOrEqual(editor().intrinsicContentSize.height, 18)
    }

    func testSwiftUIVStackProposesBoundedWidthAndUsesWrappedHeight() async {
        let text = String(repeating: "W", count: 150)
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
            InlineTextEditor(text: text, isCompleted: false, focusRequest: 0, focusAtEndRequest: 0,
                             onBeginEditing: {}, onTextChange: { _ in },
                             onSubmit: {}, onEmptyDelete: {})
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 180))
        host.setFrameSize(NSSize(width: 180, height: host.fittingSize.height))
        let window = window(containing: host)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func findEditor(in view: NSView) -> InlineEditorTextView? {
            if let editor = view as? InlineEditorTextView { return editor }
            return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
        }
        guard let view = findEditor(in: host) else {
            return XCTFail("SwiftUI must install the native editor")
        }
        XCTAssertGreaterThan(view.bounds.width, 100)
        XCTAssertLessThanOrEqual(view.bounds.width, 180)
        XCTAssertGreaterThan(view.bounds.height, 18)
        XCTAssertGreaterThanOrEqual(view.bounds.height, view.height(forWidth: view.bounds.width))
        XCTAssertEqual(view.fittingSize.height, view.intrinsicContentSize.height)
        XCTAssertNil(view.enclosingScrollView)
    }
}

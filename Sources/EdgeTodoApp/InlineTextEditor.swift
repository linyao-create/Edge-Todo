import AppKit
import SwiftUI

@MainActor
struct InlineTextEditor: NSViewRepresentable {
    let text: String
    let isCompleted: Bool
    let focusRequest: Int
    let focusAtEndRequest: Int
    let onBeginEditing: () -> Void
    let onTextChange: (String) -> Void
    let onSubmit: () -> Void
    let onEmptyDelete: () -> Void
    var onEndEditing: () -> Void = {}
    var emptyPlaceholder: String? = nil
    var routesTaskCursor: Bool = false

    func makeNSView(context: Context) -> InlineEditorTextView {
        let view = InlineEditorTextView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: InlineEditorTextView, context: Context) {
        view.onBeginEditing = onBeginEditing
        view.onTextChange = onTextChange
        view.onSubmit = onSubmit
        view.onEmptyDelete = onEmptyDelete
        view.onEndEditing = onEndEditing
        view.emptyPlaceholder = emptyPlaceholder
        if view.routesTaskCursor != routesTaskCursor {
            view.routesTaskCursor = routesTaskCursor
            view.window?.invalidateCursorRects(for: view)
        }
        view.apply(text: text, isCompleted: isCompleted, focusRequest: focusRequest,
                   focusAtEndRequest: focusAtEndRequest)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InlineEditorTextView,
                     context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

@MainActor
final class InlineEditorTextView: NSTextView, NSTextViewDelegate {
    var onBeginEditing: () -> Void = {}
    var onTextChange: (String) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onEmptyDelete: () -> Void = {}
    var onEndEditing: () -> Void = {}

    var emptyPlaceholder: String? {
        didSet { if oldValue != emptyPlaceholder { needsDisplay = true; setAccessibilityPlaceholderValue(emptyPlaceholder) } }
    }
    var shouldDrawEmptyPlaceholder: Bool { emptyPlaceholder != nil && string.isEmpty }

    var routesTaskCursor = false

    private var lastEmittedText = ""
    private var isApplyingSnapshot = false
    private var inputDepth = 0
    private var completed = false
    private var needsStyleUpdate = true
    private var lastFocusRequest: Int?
    private var pendingFocus = false
    private var pendingFocusAtEnd = false
    private var hoverTrackingArea: NSTrackingArea?
    private let editorUndoManager = UndoManager()

    override var undoManager: UndoManager? { editorUndoManager }
    // NSTextContainer's layoutManager and NSLayoutManager's textStorage links are weak.
    // Keep the root alive for a standalone text view outside an NSScrollView.
    private let backingTextStorage: NSTextStorage?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer? = nil) {
        let resolvedContainer: NSTextContainer
        if let container {
            resolvedContainer = container
            backingTextStorage = container.layoutManager?.textStorage
        } else {
            let storage = NSTextStorage()
            let manager = NSLayoutManager()
            resolvedContainer = NSTextContainer(size: NSSize(width: max(1, frameRect.width),
                                                             height: .greatestFiniteMagnitude))
            storage.addLayoutManager(manager)
            manager.addTextContainer(resolvedContainer)
            backingTextStorage = storage
        }
        super.init(frame: frameRect, textContainer: resolvedContainer)
        delegate = self
        drawsBackground = false
        isRichText = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
        resolvedContainer.lineFragmentPadding = 0
        resolvedContainer.widthTracksTextView = false
        resolvedContainer.heightTracksTextView = false
        insertionPointColor = PanelTheme.caretNS
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateWrappingWidth(frameRect.width)
        applyStyleIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(frame:) instead")
    }

    func apply(text: String, isCompleted: Bool, focusRequest: Int, focusAtEndRequest: Int = 0) {
        if completed != isCompleted {
            completed = isCompleted
            needsStyleUpdate = true
        }
        // A parent snapshot can still contain the pre-composition string. Never replace
        // marked text or its attributes; the input method owns it until it commits.
        if !hasMarkedText(), inputDepth == 0 {
            if string != text {
                let selection = selectedRanges
                // A remote/programmatic replacement invalidates native ranges from the
                // old string. Each editor owns its history, so other rows keep theirs.
                editorUndoManager.removeAllActions()
                isApplyingSnapshot = true
                string = text
                restoreSelection(selection)
                isApplyingSnapshot = false
                needsStyleUpdate = true
                invalidateIntrinsicContentSize()
            }
            lastEmittedText = text
            applyStyleIfNeeded()
        }
        if focusRequest <= 0 {
            pendingFocus = false
            pendingFocusAtEnd = false
        } else if lastFocusRequest != focusRequest {
            pendingFocus = true
            pendingFocusAtEnd = focusAtEndRequest == focusRequest
        }
        lastFocusRequest = focusRequest
        fulfillPendingFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fulfillPendingFocus()
    }

    private func fulfillPendingFocus() {
        guard pendingFocus, let window else { return }
        if window.firstResponder === self || window.makeFirstResponder(self) {
            if pendingFocusAtEnd {
                setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
            }
            pendingFocus = false
            pendingFocusAtEnd = false
        }
    }

    override func becomeFirstResponder() -> Bool {
        let selection = selectedRanges
        guard super.becomeFirstResponder() else { return false }
        restoreSelection(selection)
        onBeginEditing()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        // Hover can move focus to another row without ending native marked text.
        // Persist that composition while this row still owns its callbacks/identity.
        if hasMarkedText() { unmarkText() }
        onEndEditing()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard let window, window.firstResponder !== self,
              let editingView = window.firstResponder as? InlineEditorTextView else { return }
        // Commit an in-progress IME composition when moving across rows, but keep
        // keyboard focus and the insertion caret in the row the user last clicked.
        editingView.unmarkText()
    }

    func textDidChange(_ notification: Notification) {
        invalidateIntrinsicContentSize()
        publishCommittedText()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inputDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        inputDepth -= 1
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // AppKit may unmark and notify inside insertText. Emit only the final replacement.
        inputDepth += 1
        super.insertText(insertString, replacementRange: replacementRange)
        inputDepth -= 1
        invalidateIntrinsicContentSize()
        publishCommittedText()
    }

    override func unmarkText() {
        super.unmarkText()
        publishCommittedText()
    }

    private func publishCommittedText() {
        guard !isApplyingSnapshot, inputDepth == 0, !hasMarkedText() else { return }
        applyStyleIfNeeded()
        guard string != lastEmittedText else { return }
        lastEmittedText = string
        onTextChange(string)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if hasMarkedText() {
            // Returning false for Return lets NSTextView insert a literal newline.
            // Consume it while the IME owns a marked composition; submit only after
            // the input method has committed the candidate text.
            return commandSelector == #selector(NSResponder.insertNewline(_:))
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            publishCommittedText()
            onSubmit()
            return true
        }
        if string.isEmpty,
           commandSelector == #selector(NSResponder.deleteBackward(_:))
            || commandSelector == #selector(NSResponder.deleteForward(_:)) {
            onEmptyDelete()
            return true
        }
        return false
    }

    private func restoreSelection(_ ranges: [NSValue]) {
        let length = (string as NSString).length
        selectedRanges = ranges.map { value in
            let range = value.rangeValue
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
    }

    private func applyStyleIfNeeded() {
        guard needsStyleUpdate, !hasMarkedText(), inputDepth == 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = 19
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: completed ? PanelTheme.completedNS : PanelTheme.textNS,
            .paragraphStyle: paragraph
        ]
        if completed { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let selection = selectedRanges
        textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: (string as NSString).length))
        typingAttributes = attributes
        restoreSelection(selection)
        needsStyleUpdate = false
        invalidateIntrinsicContentSize()
    }

    func textHitRects() -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        var result: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: textContainer)) { _, usedRect, _, _, _ in
            result.append(usedRect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).insetBy(dx: -2, dy: 0))
        }
        return result
    }

    override func resetCursorRects() {
        if !routesTaskCursor { super.resetCursorRects() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard shouldDrawEmptyPlaceholder, let emptyPlaceholder else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: PanelTheme.todayPlaceholderNS
        ]
        (emptyPlaceholder as NSString).draw(at: textContainerOrigin, withAttributes: attributes)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateWrappingWidth(newSize.width)
    }

    private func updateWrappingWidth(_ width: CGFloat) {
        guard let textContainer else { return }
        let width = max(1, width.isFinite ? width : 1)
        guard textContainer.containerSize.width != width else { return }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        invalidateIntrinsicContentSize()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        updateWrappingWidth(width)
        guard let layoutManager, let textContainer else { return 18 }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let extra = layoutManager.extraLineFragmentTextContainer === textContainer
            ? layoutManager.extraLineFragmentRect.maxY : 0
        return max(18, ceil(max(used.maxY, extra)))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    override var fittingSize: NSSize {
        NSSize(width: max(1, bounds.width), height: height(forWidth: bounds.width))
    }
}


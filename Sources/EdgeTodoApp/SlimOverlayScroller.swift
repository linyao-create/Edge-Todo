import AppKit
import SwiftUI

@MainActor
final class SlimOverlayScroller: NSScroller {
    static let visualThumbWidth: CGFloat = 4
    private static let thumbRightInset: CGFloat = 1

    // Without this opt-in AppKit silently falls back to legacy rendering,
    // even when the enclosing scroll view requests overlay scrollers.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override var doubleValue: Double {
        didSet { if doubleValue != oldValue { needsDisplay = true } }
    }

    override var knobProportion: CGFloat {
        didSet { if knobProportion != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollerStyle = .overlay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        scrollerStyle = .overlay
    }

    static func visualThumbRect(for knobRect: NSRect, in scrollerBounds: NSRect) -> NSRect {
        let width = min(visualThumbWidth, scrollerBounds.width)
        guard width > 0, knobRect.height > 0 else { return .zero }
        let rightInset = min(thumbRightInset, max(0, scrollerBounds.width - width))
        return NSRect(x: scrollerBounds.maxX - width - rightInset,
            y: knobRect.minY, width: width, height: knobRect.height)
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Keep the overlay track transparent, including while hovered.
    }

    override func drawKnob() {
        // The track is transparent. Clear the previous thumb from the backing
        // surface instead of accumulating drawings as its position changes.
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        let knobRect = rect(for: .knob)
        let thumbRect = Self.visualThumbRect(for: knobRect, in: bounds)
        guard !thumbRect.isEmpty else { return }
        PanelTheme.scrollThumbNS.setFill()
        NSBezierPath(roundedRect: thumbRect,
            xRadius: Self.visualThumbWidth / 2,
            yRadius: Self.visualThumbWidth / 2).fill()
    }
}

struct SlimOverlayScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollerInstallerView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollerInstallerView)?.installIfNeeded()
    }

    @MainActor
    private final class ScrollerInstallerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installIfNeeded()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            installIfNeeded()
        }

        override func layout() {
            super.layout()
            installIfNeeded()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func installIfNeeded() {
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.autohidesScrollers = true
                    scrollView.hasVerticalScroller = true
                    guard !(scrollView.verticalScroller is SlimOverlayScroller) else { return }
                    let scroller = SlimOverlayScroller(frame: NSRect(x: 0, y: 0, width: 8, height: 80))
                    scroller.controlSize = .small
                    scrollView.verticalScroller = scroller
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

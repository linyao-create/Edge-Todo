import AppKit
import XCTest
@testable import EdgeTodoApp

@MainActor
final class ScrollerRenderingTests: XCTestCase {
    func testScrollingPaintsOneThumbAtItsCurrentPosition() async throws {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 240))
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScroller = SlimOverlayScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 240))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 800))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        window.orderFrontRegardless()
        scroll.flashScrollers()
        try await Task.sleep(for: .milliseconds(100))
        // macOS can switch styles based on the user's settings/input device.
        // Both paths must erase the old thumb from the same backing surface.
        for style in [NSScroller.Style.legacy, .overlay] {
            scroll.scrollerStyle = style
            scroll.layoutSubtreeIfNeeded()
            let scroller = try XCTUnwrap(scroll.verticalScroller)
            XCTAssertEqual(scroller.scrollerStyle, style)
            let bitmap = try XCTUnwrap(scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            for position in [80.0, 400.0, 0.0, 560.0] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
                scroll.reflectScrolledClipView(scroll.contentView)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                scroller.drawKnob()
                NSGraphicsContext.restoreGraphicsState()
                XCTAssertEqual(thumbRuns(in: bitmap), 1,
                    "Each redraw must leave one thumb (style: \(style), position: \(position))")
            }
        }
    }

    private func thumbRuns(in bitmap: NSBitmapImageRep) -> Int {
        var runs = 0
        var previousRowWasPainted = false
        for y in 0..<bitmap.pixelsHigh {
            let painted = (0..<bitmap.pixelsWide).contains { x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
            }
            if painted && !previousRowWasPainted { runs += 1 }
            previousRowWasPainted = painted
        }
        return runs
    }
}

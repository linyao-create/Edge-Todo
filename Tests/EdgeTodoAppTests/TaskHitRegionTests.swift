import XCTest
import CoreGraphics
import AppKit
@testable import EdgeTodoApp

final class TaskHitRegionTests: XCTestCase {
    @MainActor func testMouseOwnershipStaysWithItsStartingRegion() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let editor = InlineEditorTextView(frame: NSRect(x: 40, y: 10, width: 180, height: 30))
        editor.apply(text: "测试文字", isCompleted: false, focusRequest: 0)
        _ = editor.height(forWidth: 180)
        content.addSubview(editor)
        let router = TaskInteractionRouter.RouterView()
        content.addSubview(router)
        let id = UUID()
        router.rows = [id: CGRect(x: 0, y: 0, width: 290, height: 80)]
        router.controls = [id: [CGRect(x: 0, y: 0, width: 20, height: 30)]]
        router.eligible = [id]
        var moves = 0
        var finished = 0
        router.onMove = { _, _ in moves += 1 }
        router.onFinish = { _ in finished += 1 }
        func event(_ kind: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: kind, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        XCTAssertNotNil(router.route(event(.leftMouseDown, 5, 15)))
        let text = try XCTUnwrap(editor.textHitRects().first)
        let textPoint = editor.convert(NSPoint(x: text.midX, y: text.midY), to: content)
        XCTAssertNotNil(router.route(event(.leftMouseDown, textPoint.x, textPoint.y)))
        XCTAssertNotNil(router.route(event(.leftMouseDragged, 200, 15)))
        XCTAssertEqual(moves, 0)
        XCTAssertNil(router.route(event(.leftMouseDown, 250, 40)))
        XCTAssertNil(router.route(event(.leftMouseDragged, 250, 43)))
        XCTAssertNil(router.route(event(.leftMouseUp, 250, 43)))
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(finished, 0)
        XCTAssertNil(router.route(event(.leftMouseDown, 250, 40)))
        XCTAssertNil(router.route(event(.leftMouseDragged, 250, 60)))
        XCTAssertEqual(moves, 1)
        XCTAssertNil(router.route(event(.leftMouseUp, 250, 60)))
        XCTAssertEqual(finished, 1)
    }

    func testClockEntireBoundsStayClickableFromEveryDirection() {
        let row = CGRect(x: 0, y: 0, width: 300, height: 80)
        let clock = CGRect(x: 260, y: 20, width: 31, height: 21)
        let points = [CGPoint(x: 261, y: 21), CGPoint(x: 290, y: 21),
                      CGPoint(x: 261, y: 40), CGPoint(x: 290, y: 40),
                      CGPoint(x: 275, y: 30)]
        for point in points {
            XCTAssertEqual(TaskHitRegion.classify(point, row: row, text: [], controls: [], clocks: [clock]), .clock)
        }
        XCTAssertEqual(TaskHitRegion.classify(CGPoint(x: 259, y: 30), row: row, text: [], controls: [], clocks: [clock]), .blank)
        XCTAssertEqual(TaskHitRegion.classify(CGPoint(x: 275, y: 19), row: row, text: [], controls: [], clocks: [clock]), .blank)
    }

    @MainActor func testClockPointerForDirectionalMovesAndClicks() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let editor = InlineEditorTextView(frame: NSRect(x: 40, y: 10, width: 180, height: 30))
        editor.apply(text: "测试文字", isCompleted: false, focusRequest: 0)
        _ = editor.height(forWidth: 180)
        content.addSubview(editor)
        let router = TaskInteractionRouter.RouterView()
        content.addSubview(router)
        let id = UUID()
        router.rows = [id: CGRect(x: 0, y: 0, width: 300, height: 80)]
        router.controls = [id: [CGRect(x: 0, y: 0, width: 20, height: 30)]]
        router.clocks = [id: [CGRect(x: 250, y: 20, width: 31, height: 21)]]
        router.eligible = [id]
        func event(_ kind: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let pairs: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 245, y: 30), CGPoint(x: 251, y: 30)),
            (CGPoint(x: 285, y: 30), CGPoint(x: 280, y: 30)),
            (CGPoint(x: 260, y: 15), CGPoint(x: 260, y: 21)),
            (CGPoint(x: 260, y: 45), CGPoint(x: 260, y: 40))
        ]
        for (outside, inside) in pairs {
            _ = router.route(event(.mouseMoved, outside))
            _ = router.route(event(.mouseMoved, inside))
            XCTAssertEqual(NSCursor.current, NSCursor.pointingHand)
            XCTAssertNotNil(router.route(event(.leftMouseDown, inside)))
        }
        _ = router.route(event(.mouseMoved, CGPoint(x: 260, y: 30)))
        let child = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        window.addChildWindow(child, ordered: .above)
        defer { window.removeChildWindow(child); child.close() }
        let childMove = NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
            windowNumber: child.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        XCTAssertNotNil(router.route(childMove))
        XCTAssertEqual(NSCursor.current, NSCursor.arrow)
        _ = router.route(event(.mouseMoved, CGPoint(x: 240, y: 45)))
        XCTAssertEqual(NSCursor.current, NSCursor.openHand)
        let text = try XCTUnwrap(editor.textHitRects().first)
        let p = editor.convert(NSPoint(x: text.midX, y: text.midY), to: content)
        _ = router.route(event(.mouseMoved, p))
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
    }

    func testTextControlsAndWhitespaceHaveSeparateOwnership() {
        let row = CGRect(x: 0, y: 0, width: 300, height: 80)
        let text = [CGRect(x: 30, y: 10, width: 200, height: 18), CGRect(x: 30, y: 30, width: 90, height: 18)]
        let controls = [CGRect(x: 2, y: 10, width: 18, height: 20), CGRect(x: 260, y: 10, width: 30, height: 20)]
        XCTAssertEqual(TaskHitRegion.classify(CGPoint(x: 40, y: 15), row: row, text: text, controls: controls), .text)
        XCTAssertEqual(TaskHitRegion.classify(CGPoint(x: 8, y: 15), row: row, text: text, controls: controls), .control)
        XCTAssertEqual(TaskHitRegion.classify(CGPoint(x: 270, y: 15), row: row, text: text, controls: controls), .control)
        XCTAssertEqual(TaskHitRegion.classify(CGPoint(x: 200, y: 40), row: row, text: text, controls: controls), .blank)
        XCTAssertEqual(TaskHitRegion.classify(CGPoint(x: 40, y: 70), row: row, text: text, controls: controls), .blank)
        XCTAssertEqual(TaskHitRegion.classify(CGPoint(x: 301, y: 40), row: row, text: text, controls: controls), .outside)
    }
}

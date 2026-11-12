import AppKit
import XCTest
@testable import EdgeTodoApp

@MainActor
final class MoveActionButtonTests: XCTestCase {
    func testVisibleMoveButtonUsesPointingHandCursor() throws {
        _ = NSApplication.shared
        let button = MoveActionNativeButton()
        button.actionIsVisible = true
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        let previousCursor = NSCursor.current
        defer { previousCursor.set() }

        button.cursorUpdate(with: event)

        XCTAssertTrue(NSCursor.current === NSCursor.pointingHand)
    }

    func testHiddenMoveButtonDoesNotClaimPointingHandCursor() throws {
        _ = NSApplication.shared
        let button = MoveActionNativeButton()
        button.actionIsVisible = false
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        NSCursor.arrow.set()

        button.cursorUpdate(with: event)

        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
    }
}

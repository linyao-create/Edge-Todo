import AppKit
import SwiftUI

@MainActor
final class PointingHandCursorState {
    private(set) var isActive = false

    func setHovered(_ hovered: Bool) {
        guard hovered != isActive else { return }
        if hovered { NSCursor.pointingHand.push() }
        else { NSCursor.pop() }
        isActive = hovered
    }

    func disappear() { setHovered(false) }
}

private struct PointingHandCursorModifier: ViewModifier {
    @State private var cursor = PointingHandCursorState()

    func body(content: Content) -> some View {
        content
            .onHover { cursor.setHovered($0) }
            .onDisappear { cursor.disappear() }
    }
}

extension View {
    func pointingHandOnHover() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

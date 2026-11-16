import AppKit
import SwiftUI

enum PinnedMaterialPolicy {
    static func useWindowShadow(isExpanded: Bool, isPinned: Bool, reduceTransparency: Bool) -> Bool {
        isExpanded && !useMaterial(isPinned: isPinned, reduceTransparency: reduceTransparency)
    }

    static func useMaterial(isPinned: Bool, reduceTransparency: Bool) -> Bool {
        isPinned && !reduceTransparency
    }
}

enum TaskHoverAppearance {
    static func useSubtleHighlight(isHovered: Bool, isToday: Bool, isDragging: Bool, isPinned: Bool, reduceTransparency: Bool) -> Bool {
        isHovered && isToday && !isDragging && PinnedMaterialPolicy.useMaterial(isPinned: isPinned, reduceTransparency: reduceTransparency)
    }
    static func showBackground(isHovered: Bool, isToday: Bool, isDragging: Bool, isPinned: Bool, reduceTransparency: Bool) -> Bool {
        isHovered && (!isToday || isDragging || !PinnedMaterialPolicy.useMaterial(isPinned: isPinned, reduceTransparency: reduceTransparency))
    }
}

@MainActor
struct PinnedPanelMaterial: NSViewRepresentable {
    final class PassthroughEffectView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    static func makeEffectView() -> NSVisualEffectView {
        let view = PassthroughEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        view.alphaValue = 0.88
        return view
    }
    func makeNSView(context: Context) -> NSVisualEffectView { Self.makeEffectView() }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

import AppKit
import SwiftUI

private final class CountdownFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct CountdownFloatingPresenter: NSViewRepresentable {
    let todoID: UUID
    @Binding var selectedID: UUID?
    @ObservedObject var manager: CountdownManager
    let pointerEntered: () -> Void
    let pointerExited: () -> Void
    let menuVisibilityChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(anchor: view, selected: selectedID == todoID, todoID: todoID,
            manager: manager, dismiss: { selectedID = nil }, pointerEntered: pointerEntered, pointerExited: pointerExited,
            menuVisibilityChanged: menuVisibilityChanged)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator {
        private weak var anchor: NSView?
        private weak var parent: NSWindow?
        private var panel: CountdownFloatingPanel?
        private var monitor: Any?
        private var resignation: NSObjectProtocol?
        private var dismiss: (() -> Void)?
        private var lastSize = CountdownMenuLayout.size
        private let margin: CGFloat = 12
        private var menuVisibilityChanged: ((Bool) -> Void)?

        func update(anchor: NSView, selected: Bool, todoID: UUID, manager: CountdownManager,
                    dismiss: @escaping () -> Void, pointerEntered: @escaping () -> Void, pointerExited: @escaping () -> Void,
                    menuVisibilityChanged: @escaping (Bool) -> Void) {
            self.anchor = anchor; self.dismiss = dismiss
            guard selected else { close(); return }
            guard panel == nil else { reposition(); return }
            guard let parent = anchor.window else { return }
            self.parent = parent
            self.menuVisibilityChanged = menuVisibilityChanged
            menuVisibilityChanged(true)
            let window = CountdownFloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.isReleasedWhenClosed = false; window.level = parent.level
            let menu = CountdownMenu(todoID: todoID, manager: manager, dismiss: dismiss)
                .fixedSize().background(GeometryReader { proxy in
                    Color.clear.preference(key: FloatingMenuSizeKey.self, value: proxy.size)
                })
                .onPreferenceChange(FloatingMenuSizeKey.self) { [weak self] size in
                    guard size.width > 0, size.height > 0 else { return }
                    self?.lastSize = size; self?.reposition()
                }
                .padding(margin)
                .onHover { inside in if inside { pointerEntered() } else { pointerExited() } }
            window.contentView = NSHostingView(rootView: menu)
            panel = window
            parent.addChildWindow(window, ordered: .above)
            reposition(); window.makeKeyAndOrderFront(nil)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown && event.keyCode == 53 { self.dismiss?(); return nil }
                if event.type == .scrollWheel && event.window === self.parent { self.dismiss?(); return event }
                guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return event }
                if event.window === self.panel { return event }
                if let anchor = self.anchor, event.window === self.parent,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return event }
                self.dismiss?(); return event
            }
            resignation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismiss?() }
            }
        }
        func reposition() {
            guard let anchor, let parent, let panel, let screen = parent.screen else { return }
            let anchorInScreen = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let menuFrame = CountdownPopoverPlacement.screenFrame(panel: parent.frame, anchor: anchorInScreen, screen: screen.visibleFrame, menu: lastSize, referenceHeight: CountdownMenuLayout.size.height)
            panel.setFrame(menuFrame.insetBy(dx: -margin, dy: -margin), display: true)
        }
        func close() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let resignation { NotificationCenter.default.removeObserver(resignation); self.resignation = nil }
            if let panel {
                parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close(); self.panel = nil
                menuVisibilityChanged?(false)
            }
            menuVisibilityChanged = nil
            parent = nil
        }
    }
}

private struct FloatingMenuSizeKey: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

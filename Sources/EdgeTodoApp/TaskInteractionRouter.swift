import AppKit
import SwiftUI

enum TaskHitRegion: Equatable {
    case outside, control, clock, text, blank
    static func classify(_ point: CGPoint, row: CGRect, text: [CGRect], controls: [CGRect], clocks: [CGRect] = []) -> TaskHitRegion {
        guard row.contains(point) else { return .outside }
        if clocks.contains(where: { $0.contains(point) }) { return .clock }
        if controls.contains(where: { $0.contains(point) }) { return .control }
        if text.contains(where: { $0.contains(point) }) { return .text }
        return .blank
    }
}

struct TaskControlFrames: PreferenceKey {
    static let defaultValue: [UUID: [CGRect]] = [:]
    static func reduce(value: inout [UUID: [CGRect]], nextValue: () -> [UUID: [CGRect]]) {
        for (id, frames) in nextValue() { value[id, default: []].append(contentsOf: frames) }
    }
}

struct TaskClockFrames: PreferenceKey {
    static let defaultValue: [UUID: [CGRect]] = [:]
    static func reduce(value: inout [UUID: [CGRect]], nextValue: () -> [UUID: [CGRect]]) {
        for (id, frames) in nextValue() { value[id, default: []].append(contentsOf: frames) }
    }
}

private final class EventBox: @unchecked Sendable { var event: NSEvent? }

@MainActor
struct TaskInteractionRouter: NSViewRepresentable {
    let rows: [UUID: CGRect]
    let controls: [UUID: [CGRect]]
    let clocks: [UUID: [CGRect]]
    let eligible: Set<UUID>
    let onMove: (UUID, CGPoint) -> Void
    let onFinish: (UUID) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RouterView { RouterView() }
    func updateNSView(_ view: RouterView, context: Context) {
        view.rows = rows; view.controls = controls; view.clocks = clocks; view.eligible = eligible
        view.onMove = onMove; view.onFinish = onFinish; view.onCancel = onCancel
    }

    @MainActor final class RouterView: NSView {
        var rows: [UUID: CGRect] = [:]
        var controls: [UUID: [CGRect]] = [:]
        var clocks: [UUID: [CGRect]] = [:]
        var eligible: Set<UUID> = []
        var onMove: (UUID, CGPoint) -> Void = { _, _ in }
        var onFinish: (UUID) -> Void = { _ in }
        var onCancel: () -> Void = {}
        nonisolated(unsafe) private var monitor: Any?
        private var pending: (id: UUID, start: CGPoint, active: Bool)?
        private var cursorOwned = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .cursorUpdate, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                let result = EventBox()
                MainActor.assumeIsolated {
                    if let self { result.event = self.route(event) }
                    else { result.event = event }
                }
                return result.event
            }
        }

        private func textRects(in content: NSView, row: CGRect) -> [CGRect] {
            func descendants(_ view: NSView) -> [InlineEditorTextView] {
                let own = (view as? InlineEditorTextView).map { [$0] } ?? []
                return own + view.subviews.flatMap(descendants)
            }
            return descendants(content).flatMap { editor in
                editor.textHitRects().map { editor.convert($0, to: content) }
            }.filter { $0.intersects(row) }
        }

        private func target(at point: CGPoint, content: NSView) -> (UUID, TaskHitRegion)? {
            for (id, frame) in rows where eligible.contains(id) && frame.contains(point) {
                return (id, TaskHitRegion.classify(point, row: frame, text: textRects(in: content, row: frame), controls: controls[id] ?? [], clocks: clocks[id] ?? []))
            }
            return nil
        }

        func route(_ event: NSEvent) -> NSEvent? {
            guard let window else { return event }
            if event.window !== window {
                if cursorOwned && event.window?.parent === window && (event.type == .mouseMoved || event.type == .cursorUpdate) {
                    NSCursor.arrow.set()
                    cursorOwned = false
                }
                return event
            }
            guard let content = window.contentView else { return event }
            let point = content.convert(event.locationInWindow, from: nil)
            if event.type == .keyDown, event.keyCode == 53, pending != nil {
                pending = nil; onCancel(); NSCursor.arrow.set(); return nil
            }
            if event.type == .leftMouseDragged, var session = pending {
                if !session.active && hypot(point.x - session.start.x, point.y - session.start.y) >= 6 {
                    session.active = true; window.makeFirstResponder(nil)
                }
                pending = session
                if session.active { NSCursor.closedHand.set(); onMove(session.id, point) }
                return nil
            }
            if event.type == .leftMouseUp, let session = pending {
                pending = nil
                if session.active { onFinish(session.id) }
                if let (_, hit) = target(at: point, content: content) {
                    if hit == .blank { NSCursor.openHand.set() }
                    else if hit == .clock { NSCursor.pointingHand.set() }
                    else if hit == .text { NSCursor.iBeam.set() }
                    else { NSCursor.arrow.set() }
                } else { NSCursor.arrow.set() }
                return nil
            }
            if event.type == .leftMouseDown, let (id, hit) = target(at: point, content: content), hit == .blank {
                pending = (id, point, false); return nil
            }
            if event.type == .mouseMoved || event.type == .cursorUpdate {
                if let (_, hit) = target(at: point, content: content) {
                    switch hit {
                    case .blank: NSCursor.openHand.set(); cursorOwned = true; return event.type == .cursorUpdate ? nil : event
                    case .text: NSCursor.iBeam.set(); cursorOwned = true; return event.type == .cursorUpdate ? nil : event
                    case .clock:
                        if NSCursor.current != NSCursor.pointingHand { NSCursor.pointingHand.set() }
                        cursorOwned = true
                        return event.type == .cursorUpdate ? nil : event
                    case .control: if cursorOwned { NSCursor.arrow.set(); cursorOwned = false }
                    case .outside: break
                    }
                } else if cursorOwned { NSCursor.arrow.set(); cursorOwned = false }
            }
            return event
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

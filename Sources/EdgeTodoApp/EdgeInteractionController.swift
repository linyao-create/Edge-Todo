import Foundation

enum EdgePanelState: Equatable {
    case collapsed
    case expanded
}

protocol EdgeCancellable {
    func cancel()
}

protocol EdgeScheduler {
    @discardableResult
    func schedule(after interval: TimeInterval, _ action: @escaping () -> Void) -> EdgeCancellable
}

private final class DispatchCancellation: EdgeCancellable {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

private struct DispatchEdgeScheduler: EdgeScheduler {
    @discardableResult
    func schedule(after interval: TimeInterval, _ action: @escaping () -> Void) -> EdgeCancellable {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
        return DispatchCancellation(workItem: workItem)
    }
}

final class EdgeInteractionController {
    private(set) var state: EdgePanelState = .collapsed
    private let scheduler: EdgeScheduler
    private let dwellInterval: TimeInterval
    private let collapseDelay: TimeInterval = 0.25
    private var pendingExpansion: EdgeCancellable?
    private var pendingCollapse: EdgeCancellable?
    private var isHeldOpen = false
    private var isPinned = false
    private let onSubmit: (String) -> Bool
    private let onStateChange: (EdgePanelState) -> Void

    init(
        scheduler: EdgeScheduler = DispatchEdgeScheduler(),
        dwellInterval: TimeInterval = 0.18,
        onSubmit: @escaping (String) -> Bool = { _ in true },
        onStateChange: @escaping (EdgePanelState) -> Void = { _ in }
    ) {
        self.scheduler = scheduler
        self.dwellInterval = dwellInterval
        self.onSubmit = onSubmit
        self.onStateChange = onStateChange
    }

    func pointerEntered() {
        pendingCollapse?.cancel()
        pendingCollapse = nil

        if state == .expanded { return }
        pendingExpansion?.cancel()
        pendingExpansion = scheduler.schedule(after: dwellInterval) { [weak self] in
            self?.pendingExpansion = nil
            self?.state = .expanded
            self?.onStateChange(.expanded)
        }
    }

    func reveal() {
        pendingExpansion?.cancel()
        pendingExpansion = nil
        pendingCollapse?.cancel()
        pendingCollapse = nil
        state = .expanded
        onStateChange(.expanded)
    }

    func setHeldOpen(_ heldOpen: Bool) {
        isHeldOpen = heldOpen
        if heldOpen {
            pendingCollapse?.cancel()
            pendingCollapse = nil
        }
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        if pinned { pendingCollapse?.cancel(); pendingCollapse = nil }
    }

    func pointerExited() {
        pendingExpansion?.cancel()
        pendingExpansion = nil

        guard state == .expanded, !isHeldOpen, !isPinned else { return }
        pendingCollapse?.cancel()
        pendingCollapse = scheduler.schedule(after: collapseDelay) { [weak self] in
            self?.pendingCollapse = nil
            self?.state = .collapsed
            self?.onStateChange(.collapsed)
        }
    }

    func submit(text: String) {
        guard state == .expanded else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        guard onSubmit(trimmedText) else { return }
    }

    func cancel() {
        pendingExpansion?.cancel()
        pendingExpansion = nil
        pendingCollapse?.cancel()
        pendingCollapse = nil
        isHeldOpen = false
        state = .collapsed
        onStateChange(.collapsed)
    }
}

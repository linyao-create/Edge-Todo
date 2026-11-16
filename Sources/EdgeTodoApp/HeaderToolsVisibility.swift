import Combine
import Foundation

final class HeaderToolsVisibility: ObservableObject {
    @Published private(set) var isRevealed = false
    private let scheduler: EdgeScheduler
    private var pendingFade: EdgeCancellable?

    init(scheduler: EdgeScheduler = DispatchEdgeScheduler()) { self.scheduler = scheduler }

    func pointerEntered() {
        pendingFade?.cancel()
        pendingFade = nil
        isRevealed = true
    }

    func pointerExited() {
        pendingFade?.cancel()
        pendingFade = scheduler.schedule(after: 0.15) { [weak self] in
            self?.pendingFade = nil
            self?.isRevealed = false
        }
    }

    func reset() {
        pendingFade?.cancel()
        pendingFade = nil
        isRevealed = false
    }
}

enum HeaderToolsAppearance {
    static func opacity(revealed: Bool, pinned: Bool) -> Double {
        revealed ? 1 : (pinned ? 0.65 : 0)
    }
}

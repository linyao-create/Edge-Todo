import Foundation
import Combine

@MainActor
final class CountdownManager: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var error: String?
    private let repository: CountdownRepository?
    private var refreshTimer: Timer?
    init(fileURL: URL) {
        do { repository = try CountdownRepository(fileURL: fileURL) }
        catch { repository = nil; self.error = "读取倒计时失败：\(error.localizedDescription)" }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshExpired(at: Date()) }
        }
        refreshExpired(at: Date())
    }
    func timer(for id: UUID) -> Countdown? { repository?[id] }
    func set(_ countdown: Countdown?, for id: UUID) {
        guard let repository else { return }
        do { try repository.set(countdown, for: id); revision += 1; error = nil }
        catch { self.error = "保存倒计时失败：\(error.localizedDescription)" }
    }
    func start(_ seconds: TimeInterval, for id: UUID) { set(.start(duration: seconds, now: Date()), for: id) }
    func pause(for id: UUID) { guard var item = timer(for: id) else { return }; item.pause(at: Date()); set(item, for: id) }
    func resume(for id: UUID) { guard var item = timer(for: id) else { return }; item.resume(at: Date()); set(item, for: id) }
    func refreshExpired(at now: Date) {
        guard let repository else { return }
        for id in repository.ids {
            guard var item = repository[id], item.expireIfNeeded(at: now) else { continue }
            set(item, for: id)
        }
    }
    func retain(_ ids: Set<UUID>) {
        guard let repository else { return }
        for id in repository.ids where !ids.contains(id) { set(nil, for: id) }
    }
}

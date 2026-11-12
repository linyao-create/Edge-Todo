import Foundation

struct Countdown: Codable, Equatable {
    enum Status: String, Codable { case running, paused, expired }
    private(set) var mode: Status
    private(set) var deadline: Date?
    private(set) var pausedSeconds: TimeInterval
    private(set) var maximumSeconds: TimeInterval

    static func start(duration: TimeInterval, now: Date) -> Countdown {
        let seconds = max(0, duration)
        return Countdown(mode: .running, deadline: now.addingTimeInterval(seconds), pausedSeconds: seconds, maximumSeconds: seconds)
    }
    func remaining(at now: Date) -> TimeInterval {
        switch mode {
        case .running: return min(maximumSeconds, max(0, deadline?.timeIntervalSince(now) ?? 0))
        case .paused: return max(0, pausedSeconds)
        case .expired: return 0
        }
    }
    func status(at now: Date) -> Status { mode == .running && remaining(at: now) <= 0 ? .expired : mode }
    mutating func expireIfNeeded(at now: Date) -> Bool {
        guard mode == .running, remaining(at: now) <= 0 else { return false }
        mode = .expired; deadline = nil; pausedSeconds = 0
        return true
    }
    mutating func pause(at now: Date) {
        guard mode == .running else { return }
        pausedSeconds = remaining(at: now); deadline = nil; mode = pausedSeconds > 0 ? .paused : .expired
    }
    mutating func resume(at now: Date) {
        guard mode == .paused else { return }
        maximumSeconds = pausedSeconds; deadline = now.addingTimeInterval(pausedSeconds); mode = .running
    }
}

final class CountdownRepository {
    private let fileURL: URL
    private var values: [UUID: Countdown]
    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            values = try JSONDecoder().decode([UUID: Countdown].self, from: Data(contentsOf: fileURL))
        } else { values = [:] }
    }
    var ids: Set<UUID> { Set(values.keys) }
    subscript(id: UUID) -> Countdown? { values[id] }
    func set(_ timer: Countdown?, for id: UUID) throws {
        var updated = values; updated[id] = timer
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
        values = updated
    }
}

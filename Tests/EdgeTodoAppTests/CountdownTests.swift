import XCTest
@testable import EdgeTodoApp

final class CountdownTests: XCTestCase {
    func testTimerTracksElapsedTimePauseAndResume() {
        let start = Date(timeIntervalSince1970: 1000)
        var timer = Countdown.start(duration: 900, now: start)
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(60)), 840, accuracy: 0.001)
        timer.pause(at: start.addingTimeInterval(60))
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(300)), 840, accuracy: 0.001)
        timer.resume(at: start.addingTimeInterval(300))
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(310)), 830, accuracy: 0.001)
    }
    func testExpiryAndBackwardClockAdjustmentStayWithinOriginalDuration() {
        let start = Date(timeIntervalSince1970: 1000)
        let timer = Countdown.start(duration: 60, now: start)
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(-500)), 60)
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(61)), 0)
        XCTAssertEqual(timer.status(at: start.addingTimeInterval(61)), .expired)
        var recorded = timer
        XCTAssertTrue(recorded.expireIfNeeded(at: start.addingTimeInterval(61)))
        XCTAssertEqual(recorded.status(at: start.addingTimeInterval(-500)), .expired)
    }
    func testPersistenceAndIndependentTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("countdowns.json")
        let one = UUID(), two = UUID(), now = Date(timeIntervalSince1970: 2000)
        let repository = try CountdownRepository(fileURL: url)
        try repository.set(.start(duration: 600, now: now), for: one)
        try repository.set(.start(duration: 900, now: now), for: two)
        try repository.set(nil, for: one)
        let restored = try CountdownRepository(fileURL: url)
        XCTAssertNil(restored[one]); XCTAssertEqual(restored[two]?.remaining(at: now), 900)
    }
}

@MainActor
final class CountdownManagerTests: XCTestCase {
    func testRetainingEligibleTasksRemovesCompletedOrDeletedTimersOnly() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = CountdownManager(fileURL: directory.appendingPathComponent("countdowns.json"))
        let remaining = UUID(), removed = UUID()
        manager.start(600, for: remaining); manager.start(900, for: removed)
        manager.retain([remaining])
        XCTAssertNotNil(manager.timer(for: remaining))
        XCTAssertNil(manager.timer(for: removed))
    }
}

import XCTest
@testable import EdgeTodoApp

final class DailyArchiveSyncTests: XCTestCase {
    @MainActor
    func testSeveralSameDayItemsUpsertOneDailyRecordAndChangesUpdateThatRecord() async throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-07T04:00:00Z")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"), now: { date })
        let todo = try store.add(text: "事项一")
        _ = try store.add(text: "灵感一", category: .notes)
        let transport = DailyArchiveSyncTestTransport()
        let sync = ArchiveSyncCoordinator(store: store, metadataURL: directory.appendingPathComponent("sync.json"),
            transport: transport, now: { date })

        await sync.syncNow()
        await sync.syncNow()
        let firstRows = await transport.snapshot()
        XCTAssertEqual(firstRows.count, 1)
        XCTAssertTrue(firstRows[0].todoText.contains("☐ 事项一"))
        XCTAssertEqual(firstRows[0].notesText, "• 灵感一")

        try store.update(id: todo.id, text: "事项一已修订")
        await sync.syncNow()
        let finalRows = await transport.snapshot()
        let writeCount = await transport.writeCount()
        XCTAssertEqual(finalRows.count, 1)
        XCTAssertEqual(writeCount, 2)
        XCTAssertTrue(finalRows[0].todoText.contains("事项一已修订"))
    }

    @MainActor
    func testFailedDailyWriteIsRetriedWithoutChangingLocalContent() async throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-07T04:00:00Z")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"), now: { date })
        _ = try store.add(text: "离线也要保存")
        let transport = DailyArchiveSyncTestTransport(failFirst: true)
        let sync = ArchiveSyncCoordinator(store: store, metadataURL: directory.appendingPathComponent("sync.json"),
            transport: transport, now: { date })

        await sync.syncNow()
        XCTAssertEqual(sync.status, "本地已保存，飞书表格稍后重试")
        XCTAssertEqual(try store.load().first?.text, "离线也要保存")
        await sync.syncNow()
        let rows = await transport.snapshot()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(sync.status, "已保存到每日档案")
    }
}

private actor DailyArchiveSyncTestTransport: DailyArchiveTransport {
    private var rows: [String: DailyArchiveRecord] = [:]
    private var writes = 0
    private var failFirst: Bool

    init(failFirst: Bool = false) { self.failFirst = failFirst }

    func snapshot() -> [DailyArchiveRecord] { rows.values.sorted { $0.dateKey < $1.dateKey } }
    func writeCount() -> Int { writes }

    func upsert(_ record: DailyArchiveRecord) async throws {
        if failFirst {
            failFirst = false
            throw ArchiveTransportError.processFailed
        }
        writes += 1
        rows[record.dateKey] = record
    }
}

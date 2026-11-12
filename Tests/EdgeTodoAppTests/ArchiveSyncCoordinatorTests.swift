import XCTest
@testable import EdgeTodoApp

final class ArchiveSyncCoordinatorTests: XCTestCase {
    @MainActor
    func testStartRunsDebouncedSyncAndKeepsLocalRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        _ = try store.add(text: "启动后同步")
        let table = ArchiveSyncTestTransport()
        let sync = ArchiveSyncCoordinator(store: store, metadataURL: directory.appendingPathComponent("sync.json"),
            transport: table, debounceInterval: .milliseconds(10))
        sync.start()
        defer { sync.stop() }
        for _ in 0..<50 {
            if await table.snapshot().count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let rows = await table.snapshot()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try store.load().first?.text, "启动后同步")
    }

    @MainActor
    func testChangedAccountDoesNotWriteEitherRemoteTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        _ = try store.add(text: "只保存在本机")
        let table = ArchiveSyncTestTransport()
        let document = DailyDocumentArchiveTestTransport()
        let sync = ArchiveSyncCoordinator(store: store, metadataURL: directory.appendingPathComponent("sync.json"),
            transport: table, documentTransport: document, validateAccount: { throw ArchiveSettingsError.changedAccount })
        await sync.syncNow()
        let rows = await table.snapshot()
        let docs = await document.snapshot()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(docs.isEmpty)
        XCTAssertEqual(try store.load().first?.text, "只保存在本机")
    }

    @MainActor
    func testSyncAcknowledgesOnlySuccessfulArchiveAndSkipsUnchangedRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        _ = try store.add(text: "留档项目")
        let transport = ArchiveSyncTestTransport()
        let sync = ArchiveSyncCoordinator(store: store, metadataURL: directory.appendingPathComponent("sync.json"),
            transport: transport)

        await sync.syncNow()
        await sync.syncNow()

        let records = await transport.snapshot()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(sync.status, "已保存到每日档案")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sync.json").path))
    }

    @MainActor
    func testChangedRowsAreRetriedAndFailureDoesNotAcknowledge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        let row = try store.add(text: "第一版")
        let transport = ArchiveSyncTestTransport(failFirst: true)
        let sync = ArchiveSyncCoordinator(store: store, metadataURL: directory.appendingPathComponent("sync.json"),
            transport: transport)

        await sync.syncNow()
        XCTAssertEqual(sync.status, "本地已保存，飞书表格稍后重试")
        try store.update(id: row.id, text: "第二版")
        await sync.syncNow()

        let records = await transport.records
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].todoText.contains("第二版"))
        XCTAssertEqual(sync.status, "已保存到每日档案")
    }

    @MainActor
    func testDocumentIsUpdatedOnceThenOnlyWhenDailySnapshotChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        let todo = try store.add(text: "先写入表格和文档")
        let document = DailyDocumentArchiveTestTransport()
        let sync = ArchiveSyncCoordinator(store: store, metadataURL: directory.appendingPathComponent("sync.json"),
            transport: ArchiveSyncTestTransport(), documentTransport: document)

        await sync.syncNow()
        await sync.syncNow()
        let firstUpdates = await document.snapshot()
        XCTAssertEqual(firstUpdates.count, 1)

        try store.update(id: todo.id, text: "文档也要更新")
        await sync.syncNow()
        let updates = await document.snapshot()
        XCTAssertEqual(updates.count, 2)
        XCTAssertTrue(updates.last?.contains("文档也要更新") == true)
    }

    @MainActor
    func testFailedDocumentWriteIsRetriedWithoutBlockingTableArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
        _ = try store.add(text: "本地和表格照常")
        let table = ArchiveSyncTestTransport()
        let document = DailyDocumentArchiveTestTransport(failFirst: true)
        let sync = ArchiveSyncCoordinator(store: store, metadataURL: directory.appendingPathComponent("sync.json"),
            transport: table, documentTransport: document)

        await sync.syncNow()
        let tableRows = await table.snapshot()
        XCTAssertEqual(tableRows.count, 1)
        XCTAssertEqual(sync.status, "本地已保存，飞书文档稍后重试")

        await sync.syncNow()
        let documentUpdates = await document.snapshot()
        XCTAssertEqual(documentUpdates.count, 1)
    }
}

private actor ArchiveSyncTestTransport: DailyArchiveTransport {
    private(set) var records: [DailyArchiveRecord] = []
    private var failFirst: Bool

    init(failFirst: Bool = false) { self.failFirst = failFirst }

    func snapshot() -> [DailyArchiveRecord] { records }

    func upsert(_ record: DailyArchiveRecord) async throws {
        if failFirst {
            failFirst = false
            throw ArchiveTransportError.processFailed
        }
        records.append(record)
    }
}

private actor DailyDocumentArchiveTestTransport: DailyDocumentArchiveTransport {
    private(set) var contents: [String] = []
    private var failFirst: Bool

    init(failFirst: Bool = false) { self.failFirst = failFirst }

    func snapshot() -> [String] { contents }

    func update(records: [DailyArchiveRecord]) async throws {
        if failFirst {
            failFirst = false
            throw ArchiveTransportError.processFailed
        }
        contents.append(DailyDocumentArchiveRenderer.render(records))
    }
}

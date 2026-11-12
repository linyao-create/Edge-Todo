import Foundation
import Combine
import OSLog

@MainActor
final class ArchiveSyncCoordinator: ObservableObject {
    @Published private(set) var status = "正在连接飞书…"

    private let store: TodoStore
    private let logger = Logger(subsystem: "com.codex.edgetodo", category: "archive-sync")
    private let transport: any DailyArchiveTransport
    private let validateAccount: () async throws -> Void
    private let documentTransport: (any DailyDocumentArchiveTransport)?
    private let metadataURL: URL
    private let now: () -> Date
    private let calendar: Calendar
    private let retryInterval: Duration
    private let debounceInterval: Duration
    private var acknowledgements: [String: String] = [:]
    private var debounceTask: Task<Void, Never>?
    private var activeDebounce: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var isSyncing = false
    private var isStarted = false
    private var needsAnotherSync = false

    init(store: TodoStore, metadataURL: URL, transport: any DailyArchiveTransport,
         documentTransport: (any DailyDocumentArchiveTransport)? = nil,
         validateAccount: @escaping () async throws -> Void = {},
         now: @escaping () -> Date = Date.init, calendar: Calendar = .current,
         retryInterval: Duration = .seconds(30), debounceInterval: Duration = .milliseconds(750)) {
        self.store = store
        self.metadataURL = metadataURL
        self.transport = transport
        self.documentTransport = documentTransport
        self.validateAccount = validateAccount
        self.now = now
        self.calendar = calendar
        self.retryInterval = retryInterval
        self.debounceInterval = debounceInterval
        do {
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                acknowledgements = try JSONDecoder().decode([String: String].self,
                    from: Data(contentsOf: metadataURL))
            }
        } catch {
            status = "飞书同步状态损坏，保留本地数据"
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        store.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleSync() }
        }
        scheduleSync()
        pollingTask = Task { [weak self, retryInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: retryInterval)
                guard !Task.isCancelled else { return }
                await self?.syncNow()
            }
        }
    }

    func stop() {
        store.onChange = nil
        debounceTask?.cancel()
        pollingTask?.cancel()
        activeDebounce?.cancel()
        debounceTask = nil
        activeDebounce = nil
        pollingTask = nil
        isStarted = false
    }

    func syncNow() async {
        guard !isSyncing else { needsAnotherSync = true; return }
        debounceTask?.cancel()
        debounceTask = nil
        isSyncing = true
        defer {
            isSyncing = false
            if needsAnotherSync {
                needsAnotherSync = false
                scheduleSync()
            }
        }
        do {
            try await validateAccount()
            try Task.checkCancellation()
            let rows = try snapshots()
            // An empty local store should not overwrite the remote archive.
            guard rows.contains(where: { !$0.todoText.isEmpty || !$0.notesText.isEmpty }) else {
                status = "飞书归档已开启，等待本地记录"
                return
            }
            var failures: [String] = []
            do { try await syncTable(rows) }
            catch is CancellationError { throw CancellationError() }
            catch { failures.append("表格") }
            if let documentTransport {
                do { try await syncDocument(rows, using: documentTransport) }
                catch is CancellationError { throw CancellationError() }
                catch { failures.append("文档") }
            }
            if failures.isEmpty {
                status = "已保存到每日档案"
            } else {
                logger.error("Feishu archive write failed")
                status = "本地已保存，飞书\(failures.joined(separator: "、"))稍后重试"
            }
        } catch is CancellationError {
            // A stopped session must not acknowledge stale work.
        } catch {
            logger.error("Feishu archive validation failed")
            status = error is ArchiveSettingsError ? error.localizedDescription : "本地已保存，飞书同步稍后重试"
        }
    }

    private func snapshots() throws -> [DailyArchiveRecord] {
        try DailyArchiveRecord.snapshots(todos: store.loadArchive(), through: now(), calendar: calendar)
    }

    private func syncTable(_ rows: [DailyArchiveRecord]) async throws {
        let todayKey = rows.last?.dateKey
        for row in rows {
            try Task.checkCancellation()
            let key = "daily:v1:\(row.dateKey)"
            if row.dateKey != todayKey, acknowledgements[key] != nil { continue }
            guard acknowledgements[key] != row.fingerprint else { continue }
            try await transport.upsert(row)
            try Task.checkCancellation()
            guard try snapshots().first(where: { $0.dateKey == row.dateKey })?.fingerprint == row.fingerprint else {
                needsAnotherSync = true
                continue
            }
            try acknowledge(row.fingerprint, for: key)
        }
    }

    private func syncDocument(_ rows: [DailyArchiveRecord], using transport: any DailyDocumentArchiveTransport) async throws {
        let key = "document:v1"
        let fingerprint = DailyDocumentArchiveRenderer.fingerprint(rows)
        guard acknowledgements[key] != fingerprint else { return }
        try Task.checkCancellation()
        try await transport.update(records: rows)
        try Task.checkCancellation()
        guard try DailyDocumentArchiveRenderer.fingerprint(snapshots()) == fingerprint else {
            needsAnotherSync = true
            return
        }
        try acknowledge(fingerprint, for: key)
    }

    private func scheduleSync() {
        guard isStarted else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled, let self else { return }
            if self.isSyncing { self.needsAnotherSync = true; return }
            self.activeDebounce = self.debounceTask
            self.debounceTask = nil
            await self.syncNow()
            self.activeDebounce = nil
        }
    }

    private func acknowledge(_ fingerprint: String, for key: String) throws {
        var updated = acknowledgements
        updated[key] = fingerprint
        try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(updated)
        try data.write(to: metadataURL, options: .atomic)
        acknowledgements = updated
    }
}

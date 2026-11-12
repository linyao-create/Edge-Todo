import XCTest
@testable import EdgeTodoApp

final class DailyArchiveTransportTests: XCTestCase {
    func testUpsertLooksUpDateBeforeCreatingOrUpdatingSingleDailyRow() async throws {
        let settings = ArchiveSettings(table: "https://sample.feishu.cn/base/ExampleBase?table=tblDAILY",
                                       document: "https://sample.feishu.cn/docx/ExampleDoc", profile: "test",
                                       cliPath: "/bin/echo", accountID: "ou_test")
        let target = try ArchiveDestination(table: settings.table, document: settings.document)
        let day = DailyArchiveRecord(dateKey: "2026-10-07", todoText: "未完成\n☐ 买牛奶", notesText: "• 灵感")
        let empty = try JSONSerialization.data(withJSONObject: ["ok": true, "identity": "user", "data": [
            "data": [], "fields": ["日期"], "field_id_list": ["fldDATE"],
            "record_id_list": [], "has_more": false
        ]])
        let created = Data(#"{"ok":true,"identity":"user","data":{"created":true,"record":{"record_id_list":["recDAILY"]}}}"#.utf8)
        let createProcess = DailyArchiveTransportProcess(responses: [empty, created])
        try await FeishuDailyArchiveTransport(target: target, connection: ArchiveConnection(settings: settings, process: createProcess)).upsert(day)
        let createCalls = await createProcess.arguments
        XCTAssertEqual(createCalls.count, 2)
        XCTAssertEqual(createCalls[0].first, "--profile=test")
        XCTAssertTrue(createCalls[1].contains("ExampleBase"))
        XCTAssertTrue(createCalls[0].joined(separator: " ").contains("2026-10-07"))
        XCTAssertFalse(createCalls[1].contains("--record-id"))
        let payload = try XCTUnwrap(createCalls[1].last).data(using: .utf8)!
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: String])
        XCTAssertEqual(fields, ["日期": "2026-10-07", "今日待办": day.todoText, "随记": day.notesText])

        let existing = try JSONSerialization.data(withJSONObject: ["ok": true, "identity": "user", "data": [
            "data": [["2026-10-07"]], "fields": ["日期"], "field_id_list": ["fldDATE"],
            "record_id_list": ["recDAILY"], "has_more": false
        ]])
        let updated = Data(#"{"ok":true,"identity":"user","data":{"updated":true,"record":{"update":{"日期":"2026-10-07"}}}}"#.utf8)
        let updateProcess = DailyArchiveTransportProcess(responses: [existing, updated])
        try await FeishuDailyArchiveTransport(target: target, connection: ArchiveConnection(settings: settings, process: updateProcess)).upsert(day)
        let updateCalls = await updateProcess.arguments
        XCTAssertEqual(updateCalls.count, 2)
        XCTAssertTrue(updateCalls[1].contains("recDAILY"))
    }

    func testDateLookupRejectsDuplicateRowsAndNonUserResponses() throws {
        func response(_ dates: [[String]], ids: [String], identity: String = "user", more: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["ok": true, "identity": identity,
                "data": ["data": dates, "fields": ["日期"], "field_id_list": ["fldDATE"],
                    "record_id_list": ids, "has_more": more]])
        }
        XCTAssertNil(try FeishuDailyArchiveTransport.parseList(try response([], ids: []), dateKey: "2026-10-07"))
        XCTAssertEqual(try FeishuDailyArchiveTransport.parseList(
            response([["2026-10-07"]], ids: ["recDAILY"]), dateKey: "2026-10-07"), "recDAILY")
        XCTAssertThrowsError(try FeishuDailyArchiveTransport.parseList(
            response([["2026-10-07"], ["2026-10-07"]], ids: ["recA", "recB"]), dateKey: "2026-10-07"))
        XCTAssertThrowsError(try FeishuDailyArchiveTransport.parseList(
            response([], ids: [], identity: "bot"), dateKey: "2026-10-07"))
    }
}

private actor DailyArchiveTransportProcess: ArchiveProcessRunning {
    private let responses: [Data]
    private(set) var arguments: [[String]] = []

    init(responses: [Data]) { self.responses = responses }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ArchiveProcessResult {
        self.arguments.append(arguments)
        return ArchiveProcessResult(stdout: responses[self.arguments.count - 1], stderr: Data(), exitCode: 0)
    }
}

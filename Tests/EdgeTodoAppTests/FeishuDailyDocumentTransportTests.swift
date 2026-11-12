import XCTest
@testable import EdgeTodoApp

final class FeishuDailyDocumentTransportTests: XCTestCase {
    func testUpdateArgumentsTargetTheDedicatedUserDocumentAndReadGeneratedXMLFromStandardInput() {
        let arguments = FeishuDailyDocumentTransport.updateArguments(documentID: "doc-test")

        XCTAssertEqual(arguments, ["docs", "+update", "--as", "user", "--doc", "doc-test",
            "--command", "overwrite", "--content", "-"])
    }

    func testOnlyConfirmsSuccessfulUserScopedDocumentUpdate() throws {
        let valid = Data(#"{"ok":true,"identity":"user","data":{"result":"success"}}"#.utf8)
        XCTAssertNoThrow(try FeishuDailyDocumentTransport.validateUpdate(valid))

        let failed = Data(#"{"ok":true,"identity":"user","data":{"result":"failed"}}"#.utf8)
        XCTAssertThrowsError(try FeishuDailyDocumentTransport.validateUpdate(failed))

        let wrongIdentity = Data(#"{"ok":true,"identity":"bot","data":{"result":"success"}}"#.utf8)
        XCTAssertThrowsError(try FeishuDailyDocumentTransport.validateUpdate(wrongIdentity))
    }

    func testTransportSendsRenderedArchiveThroughProcessStandardInput() async throws {
        let record = DailyArchiveRecord(dateKey: "2026-10-07", todoText: "未完成\n☐ 接入文档", notesText: "• 灵感")
        let process = FeishuDocumentProcess()

        let settings = ArchiveSettings(table: "", document: "", profile: "test", cliPath: "/bin/echo", accountID: "ou_test")
        let connection = try ArchiveConnection(settings: settings, process: process)
        try await FeishuDailyDocumentTransport(documentID: "ExampleDoc", connection: connection).update(records: [record])

        let call = await process.snapshot()
        XCTAssertEqual(call.arguments, ["--profile=test"] + FeishuDailyDocumentTransport.updateArguments(documentID: "ExampleDoc"))
        XCTAssertEqual(call.input, Data(DailyDocumentArchiveRenderer.render([record]).utf8))
    }
}

private actor FeishuDocumentProcess: ArchiveProcessRunning {
    private var arguments: [String] = []
    private var input = Data()

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ArchiveProcessResult {
        ArchiveProcessResult(stdout: Data(), stderr: Data(), exitCode: 1)
    }

    func runWithInput(executable: URL, arguments: [String], standardInput: Data,
                      timeout: TimeInterval) async throws -> ArchiveProcessResult {
        self.arguments = arguments
        input = standardInput
        return ArchiveProcessResult(
            stdout: Data(#"{"ok":true,"identity":"user","data":{"result":"success"}}"#.utf8),
            stderr: Data(), exitCode: 0)
    }

    func snapshot() -> (arguments: [String], input: Data) { (arguments, input) }
}

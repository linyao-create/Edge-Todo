import XCTest
@testable import EdgeTodoApp

final class ArchiveConnectionTests: XCTestCase {
    func testConnectionChecksUserAndReadsConfiguredTargets() async throws {
        let settings = ArchiveSettings(table: "https://sample.feishu.cn/base/ExampleBase?table=tblExample",
                                       document: "https://sample.feishu.cn/docx/ExampleDoc", profile: "example",
                                       cliPath: "/bin/echo", accountID: "")
        let target = try ArchiveDestination(table: settings.table, document: settings.document)
        let cli = ConnectionProcess(responses: [
            #"{"identities":{"user":{"openId":"ou_example"}}}"#,
            #"{"ok":true,"identity":"user","data":{"items":[{"name":"日期","type":"text"},{"name":"今日待办","type":"text"},{"name":"随记","type":"text"}]}}"#,
            #"{"ok":true,"identity":"user","data":{}}"#
        ])
        let connection = try ArchiveConnection(settings: settings, process: cli)
        let user = try await connection.accountID(verify: true)
        XCTAssertEqual(user, "ou_example")
        try await connection.checkTargets(target)
        let arguments = await cli.arguments
        XCTAssertEqual(arguments[0], ["--profile=example", "auth", "status", "--json", "--verify"])
        XCTAssertTrue(arguments[1].contains("ExampleBase"))
        XCTAssertTrue(arguments[1].contains("tblExample"))
        XCTAssertTrue(arguments[2].contains("ExampleDoc"))
    }

    func testFieldCheckRejectsDateFieldWithTheWrongType() {
        let data = Data(#"{"ok":true,"identity":"user","data":{"items":[{"name":"日期","type":"datetime"},{"name":"今日待办","type":"text"},{"name":"随记","type":"text"}]}}"#.utf8)
        XCTAssertThrowsError(try ArchiveConnection.validateFields(data))
    }
}

private actor ConnectionProcess: ArchiveProcessRunning {
    let responses: [String]
    private(set) var arguments: [[String]] = []

    init(responses: [String]) { self.responses = responses }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ArchiveProcessResult {
        let response = responses[self.arguments.count]
        self.arguments.append(arguments)
        return ArchiveProcessResult(stdout: Data(response.utf8), stderr: Data(), exitCode: 0)
    }
}

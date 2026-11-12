import XCTest
@testable import EdgeTodoApp

final class ArchiveDestinationTests: XCTestCase {
    func testFreshDirectoryIsLocalOnlyEvenWithLegacySyncMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("feishu-sync.json"))
        XCTAssertNil(try ArchiveSettings.load(from: directory))
    }

    func testOnlyDirectFeishuTableAndDocumentLinksAreAccepted() throws {
        let target = try ArchiveDestination(table: "https://sample.feishu.cn/base/ExampleBase?table=tblExample&view=vewExample",
                                            document: "https://sample.feishu.cn/docx/ExampleDoc")
        XCTAssertEqual(target.baseToken, "ExampleBase")
        XCTAssertEqual(target.tableID, "tblExample")
        XCTAssertEqual(target.documentID, "ExampleDoc")
        for badTable in ["https://evil.test/base/ExampleBase?table=tblExample", "https://sample.feishu.cn/base/ExampleBase",
                         "https://sample.feishu.cn/base/ExampleBase?table=tblOne&table=tblTwo",
                         "https://sample.feishu.cn/wiki/ExampleBase?table=tblExample"] {
            XCTAssertThrowsError(try ArchiveDestination(table: badTable, document: target.documentURL.absoluteString))
        }
    }

    func testSettingsRoundTripAndDisableLeaveLocalRecordsIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localData = directory.appendingPathComponent("todos.json")
        try Data("[1]".utf8).write(to: localData)
        let settings = ArchiveSettings(table: "https://sample.feishu.cn/base/Example?table=tblExample",
                                       document: "https://sample.feishu.cn/docx/ExampleDoc", profile: "edgetodo",
                                       cliPath: "", accountID: "ou_test")
        try settings.save(to: directory)
        XCTAssertEqual(try ArchiveSettings.load(from: directory), settings)
        try ArchiveSettings.disable(in: directory)
        XCTAssertNil(try ArchiveSettings.load(from: directory))
        XCTAssertEqual(try Data(contentsOf: localData), Data("[1]".utf8))
    }
}

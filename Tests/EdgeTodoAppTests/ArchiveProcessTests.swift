import XCTest
@testable import EdgeTodoApp

final class ArchiveProcessTests: XCTestCase {
    func testArgumentsRemainLiteralAndFailureExitIsReturned() async throws {
        let literal = "$(echo unsafe); `echo unsafe` ' \" \n"
        let output = try await ArchiveProcessRunner().run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [literal], timeout: 2)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), literal + "\n")
        let failure = try await ArchiveProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 2)
        XCTAssertNotEqual(failure.exitCode, 0)
    }

    func testStandardInputIsForwardedToTheChildProcess() async throws {
        let payload = Data("<title>归档</title>\n多行内容".utf8)
        let result = try await ArchiveProcessRunner().runWithInput(
            executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: payload, timeout: 2)

        XCTAssertEqual(result.stdout, payload)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testTimeoutAndCancellationReapSleepingProcess() async throws {
        let runner = ArchiveProcessRunner()
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05)
            XCTFail("Timeout must fail")
        } catch { XCTAssertTrue(error is ArchiveTransportError) }
        let task = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 3) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testNativeDiscoveryAndMissingCLI() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrapper = directory.appendingPathComponent("scripts/run.js")
        let native = directory.appendingPathComponent("bin/lark-cli")
        try FileManager.default.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: wrapper)
        try Data().write(to: native)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: native.path)
        XCTAssertEqual(try ArchiveProcessRunner.cliExecutable(wrapperURL: wrapper).resolvingSymlinksInPath(),
                       native.resolvingSymlinksInPath())
        XCTAssertThrowsError(try ArchiveProcessRunner.cliExecutable(wrapperURL: URL(fileURLWithPath: "/tmp/nonexistent-cli-\(UUID())")))
    }

    func testGUIEnvironmentHasKnownPATHAndDrainsBothPipes() async throws {
        let result = try await ArchiveProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], timeout: 2)
        let env = String(decoding: result.stdout, as: UTF8.self)
        let path = try XCTUnwrap(env.split(separator: "\n").first(where: { $0.hasPrefix("PATH=") }))
        let entries = Set(path.dropFirst(5).split(separator: ":").map(String.init))
        XCTAssertTrue(Set(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]).isSubset(of: entries))
        // Fixed test fixture only; no item contents are sent to a shell.
        let drained = try await ArchiveProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 5000 ]; do echo stdout; echo stderr >&2; i=$((i+1)); done"], timeout: 3)
        XCTAssertEqual(drained.stdout.count, 35000)
        XCTAssertEqual(drained.stderr.count, 35000)
    }
}

import Foundation
import Darwin

struct ArchiveProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

protocol ArchiveProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ArchiveProcessResult
    func runWithInput(executable: URL, arguments: [String], standardInput: Data,
                      timeout: TimeInterval) async throws -> ArchiveProcessResult
}

extension ArchiveProcessRunning {
    func runWithInput(executable: URL, arguments: [String], standardInput: Data,
                      timeout: TimeInterval) async throws -> ArchiveProcessResult {
        try await run(executable: executable, arguments: arguments, timeout: timeout)
    }
}

struct ArchiveProcessRunner: ArchiveProcessRunning {
    static func cliExecutable(wrapperURL: URL? = nil) throws -> URL {
        if let wrapperURL { return try resolveExecutable(wrapperURL) }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let standard = ["/opt/homebrew/bin", "/usr/local/bin",
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        for directory in standard + paths where directory.hasPrefix("/") {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("lark-cli")
            if let executable = try? resolveExecutable(url) { return executable }
        }
        throw ArchiveTransportError.missingCLI
    }

    private static func resolveExecutable(_ wrapperURL: URL) throws -> URL {
        let resolved = wrapperURL.resolvingSymlinksInPath()
        let native = resolved.lastPathComponent == "run.js"
            ? resolved.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/lark-cli")
            : resolved
        guard native.pathExtension != "js", FileManager.default.isExecutableFile(atPath: native.path)
        else { throw ArchiveTransportError.missingCLI }
        return native
    }
    func run(executable: URL, arguments: [String], timeout: TimeInterval = 40) async throws -> ArchiveProcessResult {
        try await runProcess(executable: executable, arguments: arguments, standardInput: nil, timeout: timeout)
    }

    func runWithInput(executable: URL, arguments: [String], standardInput: Data,
                      timeout: TimeInterval) async throws -> ArchiveProcessResult {
        try await runProcess(executable: executable, arguments: arguments, standardInput: standardInput, timeout: timeout)
    }

    private func runProcess(executable: URL, arguments: [String], standardInput: Data?,
                            timeout: TimeInterval) async throws -> ArchiveProcessResult {
        let state = ArchiveProcessState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try state.execute(executable: executable,
                            arguments: arguments, standardInput: standardInput, timeout: timeout))
                    }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { state.interrupt(cancelled: true) }
    }
}

// Foundation Process and its cancellation state are confined by this lock.
private final class ArchiveProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var interruption: Bool? // true: cancelled, false: timeout
    private var finished = false

    func interrupt(cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if interruption == nil { interruption = cancelled }
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [self] in
            lock.lock(); defer { lock.unlock() }
            if !finished && process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    func execute(executable: URL, arguments: [String], standardInput: Data?,
                 timeout: TimeInterval) throws -> ArchiveProcessResult {
        let stdout = Pipe(), stderr = Pipe()
        let inputPipe = standardInput.map { _ in Pipe() }
        lock.lock()
        if interruption != nil { lock.unlock(); throw CancellationError() }
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let systemPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [environment["PATH"], systemPath].compactMap { $0 }.joined(separator: ":")
        environment["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1"
        environment["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1"
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = inputPipe?.fileHandleForReading ?? FileHandle.nullDevice
        do { try process.run() }
        catch { finished = true; lock.unlock(); throw ArchiveTransportError.processFailed }
        lock.unlock()

        if let standardInput, let inputPipe {
            DispatchQueue.global(qos: .utility).async {
                try? inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        let output = ArchivePipeBuffer(), errors = ArchivePipeBuffer()
        let drains = DispatchGroup()
        for (pipe, buffer) in [(stdout, output), (stderr, errors)] {
            drains.enter()
            DispatchQueue.global(qos: .utility).async {
                buffer.drain(pipe.fileHandleForReading)
                drains.leave()
            }
        }
        let timer = DispatchWorkItem { [self] in interrupt(cancelled: false) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.001, timeout), execute: timer)
        process.waitUntilExit() // Worker queue only, never the main actor.
        lock.lock()
        finished = true
        let interrupted = interruption
        lock.unlock()
        timer.cancel()
        drains.wait()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        if let interrupted {
            if interrupted { throw CancellationError() }
            throw ArchiveTransportError.timedOut
        }
        guard !output.overflow, !errors.overflow else { throw ArchiveTransportError.processFailed }
        return ArchiveProcessResult(stdout: output.data, stderr: errors.data, exitCode: process.terminationStatus)
    }
}

// One drain writer, inspected only after DispatchGroup completion.
private final class ArchivePipeBuffer: @unchecked Sendable {
    private(set) var data = Data()
    private(set) var overflow = false
    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.readData(ofLength: 16_384)
            if chunk.isEmpty { return }
            if data.count + chunk.count <= 4 * 1024 * 1024 { data.append(chunk) }
            else { overflow = true } // Keep draining to prevent a full-pipe deadlock.
        }
    }
}

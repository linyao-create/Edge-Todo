import Foundation

struct ArchiveConnection: Sendable {
    let executable: URL
    let profile: String
    let process: any ArchiveProcessRunning

    init(settings: ArchiveSettings, process: any ArchiveProcessRunning = ArchiveProcessRunner()) throws {
        let profile = settings.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.isEmpty else { throw ArchiveSettingsError.profile }
        let path = settings.cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = NSString(string: path).expandingTildeInPath
        guard path.isEmpty || expanded.hasPrefix("/") else { throw ArchiveTransportError.missingCLI }
        self.executable = try ArchiveProcessRunner.cliExecutable(
            wrapperURL: path.isEmpty ? nil : URL(fileURLWithPath: expanded))
        self.profile = profile
        self.process = process
    }

    func accountID(verify: Bool = false) async throws -> String {
        var arguments = ["auth", "status", "--json"]
        if verify { arguments.append("--verify") }
        let data = try await run(arguments, action: "用户授权检查")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identities = root["identities"] as? [String: Any],
              let user = identities["user"] as? [String: Any],
              let id = user["openId"] as? String, !id.isEmpty else { throw ArchiveSettingsError.account }
        return id
    }

    func checkTargets(_ target: ArchiveDestination) async throws {
        let fieldsData = try await run(["base", "+field-list", "--as", "user", "--base-token", target.baseToken,
                                         "--table-id", target.tableID, "--json"], action: "数据表检查")
        try Self.validateFields(fieldsData)
        let documentData = try await run(["docs", "+fetch", "--as", "user", "--doc", target.documentID,
                                          "--scope", "outline", "--json"], action: "文档检查")
        _ = try Self.userData(documentData, action: "文档检查")
    }

    static func validateFields(_ data: Data) throws {
        let body = try userData(data, action: "数据表检查")
        let fields = (body["items"] ?? body["fields"]) as? [[String: Any]] ?? []
        let textFields = Set(fields.compactMap { field -> String? in
            guard let type = field["type"] as? String, type.lowercased() == "text" else { return nil }
            return (field["name"] ?? field["field_name"]) as? String
        })
        guard Set(["日期", "今日待办", "随记"]).isSubset(of: textFields) else { throw ArchiveSettingsError.fields }
    }

    private static func userData(_ data: Data, action: String) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true, root["identity"] as? String == "user",
              let body = root["data"] as? [String: Any] else { throw ArchiveSettingsError.command(action) }
        return body
    }

    func run(_ arguments: [String], action: String, input: Data? = nil, timeout: TimeInterval = 40) async throws -> Data {
        try Task.checkCancellation()
        let arguments = ["--profile=\(profile)"] + arguments
        let result: ArchiveProcessResult
        if let input {
            result = try await process.runWithInput(executable: executable, arguments: arguments,
                                                    standardInput: input, timeout: timeout)
        } else {
            result = try await process.run(executable: executable, arguments: arguments, timeout: timeout)
        }
        try Task.checkCancellation()
        guard result.exitCode == 0 else { throw ArchiveSettingsError.command(action) }
        return result.stdout
    }
}

import Foundation
import CryptoKit

struct ArchiveDestination {
    let tableURL: URL
    let documentURL: URL
    let baseToken: String
    let tableID: String
    let documentID: String

    init(table: String, document: String) throws {
        let (tableParts, baseToken) = try Self.parse(table, kind: "base")
        let (docParts, documentID) = try Self.parse(document, kind: "docx")
        let tableValues = (tableParts.queryItems ?? []).filter { $0.name == "table" }
        guard tableValues.count == 1, let tableID = tableValues.first?.value,
              tableID.hasPrefix("tbl"), Self.validID(tableID), tableID.count > 3,
              let tableURL = tableParts.url, let documentURL = docParts.url else {
            throw ArchiveSettingsError.tableLink
        }
        self.tableURL = tableURL
        self.documentURL = documentURL
        self.baseToken = baseToken
        self.tableID = tableID
        self.documentID = documentID
    }

    private static func parse(_ value: String, kind: String) throws -> (URLComponents, String) {
        let error: ArchiveSettingsError = kind == "base" ? .tableLink : .documentLink
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              host == "feishu.cn" || host.hasSuffix(".feishu.cn"),
              parts.user == nil, parts.password == nil, parts.port == nil else { throw error }
        let path = parts.path.split(separator: "/")
        guard path.count == 2, path[0] == kind, validID(String(path[1])) else { throw error }
        return (parts, String(path[1]))
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }
}

struct ArchiveSettings: Codable, Equatable {
    var table: String
    var document: String
    var profile: String
    var cliPath: String
    var accountID: String

    static let fileName = "feishu-settings.json"

    static func load(from directory: URL) throws -> Self? {
        let file = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func disable(in directory: URL) throws {
        let file = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    func metadataURL(in directory: URL, target: ArchiveDestination) -> URL {
        let key = [profile, accountID, target.baseToken, target.tableID, target.documentID].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("feishu-sync", isDirectory: true)
            .appendingPathComponent(digest + ".json")
    }
}

enum ArchiveSettingsError: LocalizedError {
    case tableLink, documentLink, profile, account, changedAccount, fields, command(String)

    var errorDescription: String? {
        switch self {
        case .tableLink: "请复制飞书多维表格里具体数据表的链接（链接中需含 table=）。"
        case .documentLink: "请复制飞书云文档直链（链接中需含 /docx/）。"
        case .profile: "请填写你在飞书 CLI 里配置的名称。"
        case .account: "没有找到已登录的飞书用户。请在终端完成授权后重试。"
        case .changedAccount: "飞书登录账号已变化，请在设置里重新检查并开启归档。"
        case .fields: "请将目标数据表中的「日期」「今日待办」「随记」设为文本字段。"
        case .command(let name): "飞书\(name)失败。请检查网络、CLI 授权和目标资源权限。"
        }
    }
}

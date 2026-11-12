import Foundation

protocol DailyDocumentArchiveTransport: Sendable {
    func update(records: [DailyArchiveRecord]) async throws
}

struct FeishuDailyDocumentTransport: DailyDocumentArchiveTransport {
    let documentID: String
    let connection: ArchiveConnection

    static func updateArguments(documentID: String) -> [String] {
        ["docs", "+update", "--as", "user", "--doc", documentID,
            "--command", "overwrite", "--content", "-"]
    }

    static func validateUpdate(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true, root["identity"] as? String == "user",
              let body = root["data"] as? [String: Any],
              body["result"] as? String == "success" else {
            throw ArchiveTransportError.invalidResponse
        }
    }

    func update(records: [DailyArchiveRecord]) async throws {
        let content = DailyDocumentArchiveRenderer.render(records)
        let result = try await connection.run(Self.updateArguments(documentID: documentID),
            action: "写入归档文档", input: Data(content.utf8), timeout: 60)
        try Self.validateUpdate(result)
    }
}

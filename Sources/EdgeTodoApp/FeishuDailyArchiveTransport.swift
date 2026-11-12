import Foundation

protocol DailyArchiveTransport: Sendable {
    func upsert(_ record: DailyArchiveRecord) async throws
}

struct FeishuDailyArchiveTransport: DailyArchiveTransport {
    let target: ArchiveDestination
    let connection: ArchiveConnection

    private static func envelope(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true, root["identity"] as? String == "user",
              let body = root["data"] as? [String: Any] else { throw ArchiveTransportError.invalidResponse }
        for container in [root, body] {
            if let ignored = container["ignored_fields"] {
                guard let array = ignored as? [Any], array.isEmpty else { throw ArchiveTransportError.invalidResponse }
            }
        }
        return body
    }

    static func parseList(_ data: Data, dateKey: String) throws -> String? {
        let body = try envelope(data)
        guard let ids = body["record_id_list"] as? [String],
              let rows = body["data"] as? [[Any]],
              let fields = body["fields"] as? [String],
              let fieldIDs = body["field_id_list"] as? [String],
              fields == ["日期"], fieldIDs.count == 1,
              body["has_more"] as? Bool == false, ids.count == rows.count, ids.count <= 1
        else { throw ArchiveTransportError.invalidResponse }
        guard let id = ids.first else { return nil }
        guard validRecordID(id), rows[0].count == 1, rows[0][0] as? String == dateKey
        else { throw ArchiveTransportError.invalidResponse }
        return id
    }

    static func validateWrite(_ data: Data, existingID: String?) throws {
        let body = try envelope(data)
        guard body[existingID == nil ? "created" : "updated"] as? Bool == true,
              let record = body["record"] as? [String: Any] else { throw ArchiveTransportError.invalidResponse }
        if let existingID {
            guard validRecordID(existingID), let update = record["update"] as? [String: Any], !update.isEmpty
            else { throw ArchiveTransportError.invalidResponse }
        } else {
            guard let ids = record["record_id_list"] as? [String], ids.count == 1, validRecordID(ids[0])
            else { throw ArchiveTransportError.invalidResponse }
        }
        if let ignored = record["ignored_fields"] {
            guard let array = ignored as? [Any], array.isEmpty else { throw ArchiveTransportError.invalidResponse }
        }
    }

    func listArguments(_ record: DailyArchiveRecord) throws -> [String] {
        let filter: [String: Any] = ["logic": "and", "conditions": [["日期", "==", record.dateKey]]]
        let json = try JSONSerialization.data(withJSONObject: filter, options: [.sortedKeys])
        return common("+record-list")
            + ["--filter-json", String(decoding: json, as: UTF8.self), "--field-id", "日期", "--limit", "2", "--json"]
    }

    func writeArguments(_ record: DailyArchiveRecord, existingID: String?) throws -> [String] {
        if let existingID, !Self.validRecordID(existingID) { throw ArchiveTransportError.invalidResponse }
        return common("+record-upsert")
            + (existingID.map { ["--record-id", $0] } ?? [])
            + ["--json", String(decoding: try record.fieldData(), as: UTF8.self)]
    }

    func upsert(_ record: DailyArchiveRecord) async throws {
        let lookup = try await connection.run(listArguments(record), action: "查找日期记录")
        let existingID = try Self.parseList(lookup, dateKey: record.dateKey)
        let write = try await connection.run(writeArguments(record, existingID: existingID), action: "保存表格记录")
        try Self.validateWrite(write, existingID: existingID)
    }

    private func common(_ command: String) -> [String] {
        ["base", command, "--as", "user", "--base-token", target.baseToken, "--table-id", target.tableID]
    }

    private static func validRecordID(_ id: String) -> Bool {
        id.hasPrefix("rec") && id.count > 3 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
        }
    }
}

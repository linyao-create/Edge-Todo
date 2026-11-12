import Foundation
import CryptoKit

enum DailyDocumentArchiveRenderer {
    static let title = "桌面随手记｜每日归档"

    static func render(_ records: [DailyArchiveRecord]) -> String {
        var xml = "<title>\(escape(title))</title><p>由桌面待办自动维护的历史副本；本机待办是数据来源。</p>"
        for record in records.sorted(by: { $0.dateKey < $1.dateKey }) {
            xml += "<h1>\(escape(record.dateKey))</h1><h2>今日待办</h2>"
            let todos = todoSections(record.todoText)
            xml += checkboxSection("已完成", items: todos.completed, done: true)
            xml += checkboxSection("未完成", items: todos.incomplete, done: false)
            xml += "<h3>已删除</h3>"
            if todos.deleted.isEmpty {
                xml += "<p>暂无。</p>"
            } else {
                xml += "<ul>" + todos.deleted.map { "<li><del>\(escape($0))</del></li>" }.joined() + "</ul>"
            }
            xml += "<h2>随记</h2>"
            let notes = record.notesText.components(separatedBy: "\n").compactMap { line -> String? in
                line.hasPrefix("• ") ? String(line.dropFirst(2)) : nil
            }
            xml += notes.isEmpty ? "<p>暂无。</p>" : "<ul>" + notes.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
        }
        return xml
    }

    static func fingerprint(_ records: [DailyArchiveRecord]) -> String {
        let content = records.sorted(by: { $0.dateKey < $1.dateKey })
            .map(\.fingerprint).joined(separator: "\n")
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func todoSections(_ value: String) -> (completed: [String], incomplete: [String], deleted: [String]) {
        var section = ""
        var completed: [String] = []
        var incomplete: [String] = []
        var deleted: [String] = []
        for line in value.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if ["已完成", "未完成", "已删除"].contains(trimmed) {
                section = trimmed
                continue
            }
            if trimmed.hasPrefix("☑ ") { completed.append(String(trimmed.dropFirst(2))) }
            else if trimmed.hasPrefix("☐ ") { incomplete.append(String(trimmed.dropFirst(2))) }
            else if trimmed.hasPrefix("• ") { deleted.append(String(trimmed.dropFirst(2))) }
            else {
                switch section {
                case "已完成": completed.append(trimmed)
                case "未完成": incomplete.append(trimmed)
                case "已删除": deleted.append(trimmed)
                default: break
                }
            }
        }
        return (completed, incomplete, deleted)
    }

    private static func checkboxSection(_ title: String, items: [String], done: Bool) -> String {
        "<h3>\(title)</h3>" + (items.isEmpty ? "<p>暂无。</p>" :
            items.map { "<checkbox done=\"\(done ? "true" : "false")\">\(escape($0))</checkbox>" }.joined())
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br/>")
    }
}

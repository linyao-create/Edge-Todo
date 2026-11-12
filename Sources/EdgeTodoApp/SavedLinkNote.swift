import Foundation

enum SavedLinkSourceIcon: Equatable {
    case youtube
    case xiaohongshu
    case bilibili

    var pngData: Data? {
        let name: String
        switch self {
        case .youtube: name = "youtube"
        case .xiaohongshu: name = "xiaohongshu"
        case .bilibili: name = "bilibili"
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "SiteIcons") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    static func forDomain(_ domain: String) -> Self? {
        func matches(_ root: String) -> Bool {
            domain == root || domain.hasSuffix(".\(root)")
        }

        if matches("youtube.com") || matches("youtu.be") { return .youtube }
        if matches("xiaohongshu.com") || matches("xhslink.cn") { return .xiaohongshu }
        if matches("bilibili.com") || matches("b23.tv") { return .bilibili }
        return nil
    }
}

/// A link note is either one complete web address or a title followed by one web address.
/// Keep its original text intact so existing local records and archive exports stay compatible.
struct SavedLinkNote: Equatable {
    let originalText: String
    let url: URL
    let title: String
    let domain: String

    var sourceIcon: SavedLinkSourceIcon? { SavedLinkSourceIcon.forDomain(domain) }

    init?(text: String) {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        guard (1...2).contains(lines.count) else { return nil }
        let address = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !address.isEmpty,
              address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let normalized = address.hasPrefix("www.") ? "https://\(address)" : address
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let resolvedURL = components.url else { return nil }

        let rawTitle = lines.count == 2
            ? lines[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard lines.count == 1 || !rawTitle.isEmpty else { return nil }
        let shortDomain = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host.lowercased()
        let isXiaohongshu = shortDomain == "xiaohongshu.com"
            || shortDomain.hasSuffix(".xiaohongshu.com")
            || shortDomain == "xhslink.cn"
        let genericXiaohongshuTitle = isXiaohongshu &&
            (rawTitle == "小红书" || rawTitle.hasPrefix("小红书 - ") || rawTitle.hasPrefix("小红书-"))

        originalText = text
        url = resolvedURL
        domain = shortDomain
        title = rawTitle.isEmpty || genericXiaohongshuTitle
            || rawTitle == host || rawTitle == shortDomain
            || rawTitle == address || rawTitle == resolvedURL.absoluteString
            ? (isXiaohongshu ? "小红书笔记" : shortDomain) : rawTitle
    }

}

import Foundation

enum BrowserCaptureProtocol {
    static let scheme: String = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let capture = types?.first { $0["CFBundleURLName"] as? String == "com.codex.edgetodo.capture" }
        return (capture?["CFBundleURLSchemes"] as? [String])?.first ?? "edgetodo"
    }()
}

struct BrowserCaptureContent: Equatable, Sendable {
    let title: String
    let url: URL?

    var noteText: String {
        guard let url else { return title }
        return title.isEmpty ? url.absoluteString : "\(title)\n\(url.absoluteString)"
    }
}

enum BrowserCaptureError: LocalizedError {
    case invalidRequest
    case invalidPageURL

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "保存请求不完整，请重新点击浏览器的「存当前页到随记」。"
        case .invalidPageURL:
            return "请先在浏览器打开要保存的网页，再点击「存当前页到随记」。"
        }
    }
}

enum BrowserPanelRevealRequest {
    static func matches(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == BrowserCaptureProtocol.scheme,
              components.host?.lowercased() == "show",
              components.path.isEmpty || components.path == "/",
              components.queryItems?.isEmpty ?? true,
              components.fragment == nil,
              components.user == nil, components.password == nil, components.port == nil else {
            return false
        }
        return true
    }
}

struct BrowserCaptureRequest {
    let id: UUID
    let content: BrowserCaptureContent

    init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 65_536,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == BrowserCaptureProtocol.scheme,
              components.host?.lowercased() == "capture",
              components.path.isEmpty || components.path == "/",
              components.user == nil, components.password == nil, components.port == nil,
              let items = components.queryItems,
              items.filter({ $0.name == "url" }).count == 1,
              items.filter({ $0.name == "title" }).count <= 1,
              items.filter({ $0.name == "id" }).count == 1,
              let idValue = items.first(where: { $0.name == "id" })?.value,
              let id = UUID(uuidString: idValue) else {
            throw BrowserCaptureError.invalidRequest
        }
        guard let pageValue = items.first(where: { $0.name == "url" })?.value,
              let page = URLComponents(string: pageValue),
              let scheme = page.scheme?.lowercased(), ["http", "https"].contains(scheme),
              page.host?.isEmpty == false,
              let pageURL = page.url else {
            throw BrowserCaptureError.invalidPageURL
        }
        self.id = id
        let title = items.first(where: { $0.name == "title" })?.value ?? ""
        content = BrowserCaptureContent(title: title.trimmingCharacters(in: .whitespacesAndNewlines), url: pageURL)
    }
}

final class BrowserCaptureReceiver {
    private let store: TodoStore

    init(store: TodoStore) { self.store = store }

    @discardableResult
    func receive(_ url: URL) throws -> Todo {
        let request = try BrowserCaptureRequest(url: url)
        return try store.importNote(id: request.id, text: request.content.noteText)
    }
}

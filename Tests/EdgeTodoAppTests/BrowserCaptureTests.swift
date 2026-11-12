import AppKit
import Foundation
import XCTest
@testable import EdgeTodoApp

final class BrowserCaptureTests: XCTestCase {
    func testChineseTitleAndCompletePageURLSurviveTransport() throws {
        let page = "https://www.xiaohongshu.com/explore/abc?xsec_token=a+b%2Fc&xsec_source=pc_user#评论"
        let request = try BrowserCaptureRequest(url: captureURL(title: "花 & 灵感 + 100% 🌸", page: page))
        XCTAssertEqual(request.content.title, "花 & 灵感 + 100% 🌸")
        XCTAssertEqual(request.content.url?.absoluteString, URL(string: page)?.absoluteString)
    }

    func testBlankTitleSavesOnlyTheURL() throws {
        let request = try BrowserCaptureRequest(url: captureURL(title: "  \n ", page: "https://example.com/a"))
        XCTAssertEqual(request.content.noteText, "https://example.com/a")
    }

    func testPanelRevealURLIsRecognizedOnlyForTheDedicatedEmptyRequest() throws {
        XCTAssertTrue(BrowserPanelRevealRequest.matches(try XCTUnwrap(URL(string: "edgetodo://show"))))
        XCTAssertTrue(BrowserPanelRevealRequest.matches(try XCTUnwrap(URL(string: "edgetodo://show/"))))
        for value in ["edgetodo://show?title=not-used", "edgetodo://capture", "https://show"] {
            XCTAssertFalse(BrowserPanelRevealRequest.matches(try XCTUnwrap(URL(string: value))))
        }
    }

    func testRejectsUnsupportedRequestAndNonWebPages() throws {
        for value in ["https://example.com/capture", "edgetodo://other", "edgetodo://capture"] {
            XCTAssertThrowsError(try BrowserCaptureRequest(url: XCTUnwrap(URL(string: value))))
        }
        for page in ["javascript:alert(1)", "file:///private/test.txt", "edge://settings", "https://", ""] {
            XCTAssertThrowsError(try BrowserCaptureRequest(url: captureURL(title: "页面", page: page)))
        }
    }

    func testRejectsAmbiguousParametersAndInvalidCaptureID() throws {
        var components = try XCTUnwrap(URLComponents(url: captureURL(), resolvingAgainstBaseURL: false))
        components.queryItems?.append(URLQueryItem(name: "url", value: "https://other.example"))
        XCTAssertThrowsError(try BrowserCaptureRequest(url: XCTUnwrap(components.url)))
        components.queryItems = [URLQueryItem(name: "url", value: "https://example.com"),
                                 URLQueryItem(name: "id", value: "not-a-uuid")]
        XCTAssertThrowsError(try BrowserCaptureRequest(url: XCTUnwrap(components.url)))
    }

    func testReceivePersistsImmediatelyAsNoteAndRepeatDeliveryIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("todos.json")
        let store = TodoStore(fileURL: file)
        let receiver = BrowserCaptureReceiver(store: store)
        let id = UUID()
        let requestURL = try captureURL(title: "当前笔记", page: "https://example.com/note?a=1&b=2", id: id)
        let note = try receiver.receive(requestURL)
        _ = try receiver.receive(requestURL)
        let saved = try TodoStore(fileURL: file).load()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(note.id, id)
        XCTAssertEqual(saved.first?.category, .notes)
        XCTAssertEqual(saved.first?.text, "当前笔记\nhttps://example.com/note?a=1&b=2")
    }

    func testSeparateClicksOnTheSamePageRemainSeparateNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TodoStore(fileURL: root.appendingPathComponent("todos.json"))
        let receiver = BrowserCaptureReceiver(store: store)
        _ = try receiver.receive(captureURL())
        _ = try receiver.receive(captureURL())
        XCTAssertEqual(try store.load().count, 2)
    }

    func testFailedSaveIsReportedAndTheSameRequestCanBeRetried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("todos.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let receiver = BrowserCaptureReceiver(store: TodoStore(fileURL: file))
        let url = try captureURL()
        XCTAssertThrowsError(try receiver.receive(url))
        try FileManager.default.removeItem(at: file)
        _ = try receiver.receive(url)
        XCTAssertEqual(try TodoStore(fileURL: file).load().count, 1)
    }

    private func captureURL(title: String = "当前页", page: String = "https://example.com/note", id: UUID = UUID()) throws -> URL {
        var components = URLComponents()
        components.scheme = "edgetodo"
        components.host = "capture"
        components.queryItems = [URLQueryItem(name: "title", value: title),
                                 URLQueryItem(name: "url", value: page),
                                 URLQueryItem(name: "id", value: id.uuidString)]
        return try XCTUnwrap(components.url)
    }
}

@MainActor
final class BrowserCapturePresentationTests: XCTestCase {
    func testCaptureRevealsNotesAndTargetsNewRowWithoutStartingEditing() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { throw XCTSkip("No screen") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EdgeTodoBrowserTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let selection = PanelSelectionStore(defaults: defaults)
        let store = TodoStore(fileURL: root.appendingPathComponent("todos.json"))
        let controller = EdgePanelWindowController(store: store, screen: screen, selectionStore: selection)
        defer { controller.dispose() }
        let note = try store.add(text: "浏览器来的笔记\nhttps://example.com", category: .notes)

        controller.revealCapturedNote(id: note.id)

        XCTAssertTrue(controller.isExpanded)
        XCTAssertEqual(controller.selectedCategory, .notes)
        XCTAssertEqual(selection.category, .notes)
        XCTAssertEqual(controller.capturedRowID, note.id)
        XCTAssertNil(controller.focusedRowID)
        XCTAssertTrue(controller.visibleRows.contains(where: { $0.id == note.id }))

        controller.reveal()
        XCTAssertTrue(controller.isExpanded)
    }
}

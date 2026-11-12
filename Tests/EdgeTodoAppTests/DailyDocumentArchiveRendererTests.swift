import XCTest
@testable import EdgeTodoApp

final class DailyDocumentArchiveRendererTests: XCTestCase {
    func testRendersDatesStatusesAndNotesInReadableSections() {
        let earlier = DailyArchiveRecord(dateKey: "2026-10-07",
            todoText: "已完成\n☑ 先完成\n\n未完成\n☐ 再继续", notesText: "• 一个想法")
        let later = DailyArchiveRecord(dateKey: "2026-10-08", todoText: "", notesText: "")

        let xml = DailyDocumentArchiveRenderer.render([later, earlier])

        XCTAssertTrue(xml.hasPrefix("<title>桌面随手记｜每日归档</title>"))
        XCTAssertLessThan(try! XCTUnwrap(xml.range(of: "2026-10-07")).lowerBound,
            try! XCTUnwrap(xml.range(of: "2026-10-08")).lowerBound)
        XCTAssertTrue(xml.contains("<checkbox done=\"true\">先完成</checkbox>"))
        XCTAssertTrue(xml.contains("<checkbox done=\"false\">再继续</checkbox>"))
        XCTAssertTrue(xml.contains("<li>一个想法</li>"))
        XCTAssertTrue(xml.contains("暂无"))
    }

    func testEscapesUserTextBeforeEmbeddingItInDocxXML() {
        let record = DailyArchiveRecord(dateKey: "2026-10-07",
            todoText: "未完成\n☐ A < B & C", notesText: "• <idea> & next")

        let xml = DailyDocumentArchiveRenderer.render([record])

        XCTAssertTrue(xml.contains("A &lt; B &amp; C"))
        XCTAssertTrue(xml.contains("&lt;idea&gt; &amp; next"))
    }

    func testDocumentFingerprintChangesWithAnyDailySection() {
        let first = DailyArchiveRecord(dateKey: "2026-10-07", todoText: "☐ 一", notesText: "")
        let second = DailyArchiveRecord(dateKey: "2026-10-07", todoText: "☐ 二", notesText: "")

        XCTAssertEqual(DailyDocumentArchiveRenderer.fingerprint([first]),
            DailyDocumentArchiveRenderer.fingerprint([first]))
        XCTAssertNotEqual(DailyDocumentArchiveRenderer.fingerprint([first]),
            DailyDocumentArchiveRenderer.fingerprint([second]))
    }
}

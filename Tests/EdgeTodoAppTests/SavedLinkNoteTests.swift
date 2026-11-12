import AppKit
import Foundation
import XCTest
@testable import EdgeTodoApp

final class SavedLinkNoteTests: XCTestCase {
    func testRecognizedSourcesProvideDistinctReadableSiteIcons() throws {
        let icons: [SavedLinkSourceIcon] = [.youtube, .xiaohongshu, .bilibili]
        var imageData = [Data]()

        for icon in icons {
            let data = try XCTUnwrap(icon.pngData, "Missing site icon for \(icon)")
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 32)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 32)
            imageData.append(data)
        }

        XCTAssertEqual(Set(imageData).count, icons.count)
    }

    func testRecognizedLinkHostsSelectPlatformIcons() throws {
        let cases: [(String, SavedLinkSourceIcon)] = [
            ("https://m.youtube.com/watch?v=abc", .youtube),
            ("https://youtu.be/abc", .youtube),
            ("https://www.xiaohongshu.com/explore/abc", .xiaohongshu),
            ("https://xhslink.cn/abc", .xiaohongshu),
            ("https://www.bilibili.com/video/BV1", .bilibili),
            ("https://b23.tv/abc", .bilibili)
        ]

        for (address, expected) in cases {
            let link = try XCTUnwrap(SavedLinkNote(text: address))
            XCTAssertEqual(link.sourceIcon, expected, address)
        }
    }

    func testUnknownAndLookalikeHostsKeepTheDomainLabel() throws {
        for address in [
            "https://example.com/page",
            "https://youtube.com.evil.example/page",
            "https://notbilibili.com/video"
        ] {
            let link = try XCTUnwrap(SavedLinkNote(text: address))
            XCTAssertNil(link.sourceIcon, address)
        }
    }

    func testExistingTitleAndURLBecomeACompactLinkWithoutLosingTheURL() throws {
        let originalURL = "https://www.funwithcomputervision.com/?source=note&next=a%2Fb#gallery"
        let text = "Fun With Computer Vision\n\(originalURL)"
        let link = try XCTUnwrap(SavedLinkNote(text: text))

        XCTAssertEqual(link.title, "Fun With Computer Vision")
        XCTAssertEqual(link.domain, "funwithcomputervision.com")
        XCTAssertEqual(link.url.absoluteString, originalURL)
    }

    func testLegacyXiaohongshuURLWithoutSchemeGetsShortTitleAndCompleteOpenURL() throws {
        let original = "www.xiaohongshu.com/explore/6ac5faf900000001b030425?xsec_token=AB6HFpFcr4&xsec_source=pc_feed"
        let link = try XCTUnwrap(SavedLinkNote(text: original))

        XCTAssertEqual(link.title, "小红书笔记")
        XCTAssertEqual(link.domain, "xiaohongshu.com")
        XCTAssertEqual(link.url.absoluteString, "https://\(original)")
    }

    func testGenericSiteTitleFallsBackWithoutChangingStoredText() throws {
        let text = "小红书 - 你的生活指南\nhttps://www.xiaohongshu.com/explore/abc?xsec_token=token"
        let link = try XCTUnwrap(SavedLinkNote(text: text))

        XCTAssertEqual(link.title, "小红书笔记")
        XCTAssertEqual(link.originalText, text)
    }

    func testPageUsingItsURLAsTitleStillGetsAReadableLabel() throws {
        let address = "https://example.com/very/long/path?token=abc"
        let link = try XCTUnwrap(SavedLinkNote(text: "\(address)\n\(address)"))
        XCTAssertEqual(link.title, "example.com")
        XCTAssertEqual(link.url.absoluteString, address)
    }

    func testOrdinaryNotesAndLongFormTextRemainOrdinaryText() {
        for text in [
            "明天看这个网站",
            "网站整理\nhttps://example.com\n记得关注第二部分",
            "https://",
            "file:///Users/example/secret",
            "查看 https://example.com 这个页面"
        ] {
            XCTAssertNil(SavedLinkNote(text: text), "Should not reinterpret: \(text)")
        }
    }

}

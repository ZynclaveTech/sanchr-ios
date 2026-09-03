import UIKit
import XCTest
@testable import Sanchr

/// The Help Center used to be a mock-up: untappable topics, made-up article
/// counts, a "Live Chat" that did not exist and community links that went
/// nowhere. Everything on it now derives from real content.
final class HelpCenterContentTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testEveryCategoryHasArticlesAndIDsAreUnique() {
        for category in HelpCategory.allCases {
            XCTAssertFalse(category.articles.isEmpty, "\(category.title) has no articles")
        }
        let ids = HelpContent.articles.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate article ids")
        XCTAssertGreaterThanOrEqual(HelpContent.articles.count, 25)
        for article in HelpContent.articles {
            XCTAssertFalse(article.sections.isEmpty, article.id)
            XCTAssertTrue(article.sections.allSatisfy { !$0.paragraphs.isEmpty || !$0.steps.isEmpty }, "\(article.id) has an empty section")
        }
    }

    func testEverySymbolResolves() {
        for name in HelpContent.articles.map(\.icon) + HelpCategory.allCases.map(\.icon) + ["envelope", "exclamationmark.shield", "headphones"] {
            XCTAssertNotNil(UIImage(systemName: name), "missing symbol \(name)")
        }
    }

    func testPopularTopicsAllExist() {
        XCTAssertEqual(HelpContent.popularIDs.compactMap(HelpContent.article).count, HelpContent.popularIDs.count)
    }

    func testSearchFindsArticlesByWordsInAnyOrder() {
        XCTAssertTrue(HelpContent.search("recovery key").contains { $0.id == "recovery-key" })
        XCTAssertTrue(HelpContent.search("KEY recovery").contains { $0.id == "recovery-key" })
        XCTAssertTrue(HelpContent.search("expired").contains { $0.id == "media-expired" })
        XCTAssertTrue(HelpContent.search("sign out").contains { $0.id == "delete-account" }, "the no-sign-out policy is findable")
        XCTAssertTrue(HelpContent.search("zzzz").isEmpty)
        XCTAssertTrue(HelpContent.search("a").isEmpty, "single letters do not match everything")
    }

    func testContentMatchesTheProduct() {
        let all = HelpContent.articles.map(\.searchText).joined()
        XCTAssertFalse(all.contains("group chat") || all.contains("create a group"), "the app has no group creation")
        XCTAssertTrue(all.contains("no sign-out"), "deletion is the only exit, as the app says")
        XCTAssertTrue(all.contains("video calling is being tested"), "video calls are disabled in release")
        XCTAssertTrue(all.contains("blinded"), "contact discovery is described honestly")
    }

    func testTheScreenHasNoPlaceholdersLeft() throws {
        let view = try String(contentsOf: Self.root.appendingPathComponent("Features/Settings/Presentation/HelpCenterView.swift"), encoding: .utf8)
        for placeholder in ["Live Chat", "12 articles", "Discord", "Reddit", "r/Sanchr", "communitySection", "Get instant help"] {
            XCTAssertFalse(view.contains(placeholder), "placeholder still present: \(placeholder)")
        }
        XCTAssertTrue(view.contains("HelpContent.search(searchText)"), "search is live")
        XCTAssertTrue(view.contains("category.articles.count"), "counts are real")
        XCTAssertTrue(view.contains("HelpCategoryView(category: category)"))
        XCTAssertTrue(view.contains("HelpArticleView(article: article)"))
    }
}

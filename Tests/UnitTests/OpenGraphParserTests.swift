import XCTest
import SanchrShared

/// The few tags a preview card is built from, read the same way Android reads
/// them so a link shows the same card on both.
final class OpenGraphParserTests: XCTestCase {
    private let page = URL(string: "https://example.com/news/story.html")!

    private func parse(_ html: String) -> ParsedPage { OpenGraphParser.parse(html: html, pageURL: page) }

    func testOpenGraphTagsWinOverTheTitleElement() {
        let parsed = parse("""
            <html><head><title>Fallback</title>
            <meta property="og:title" content="The Story">
            <meta property="og:image" content="https://cdn.example.com/a.jpg">
            </head></html>
            """)
        XCTAssertEqual(parsed.title, "The Story")
        XCTAssertEqual(parsed.imageURL?.absoluteString, "https://cdn.example.com/a.jpg")
    }

    func testTwitterTagsAndTheTitleElementAreFallbacks() {
        XCTAssertEqual(parse("<meta name='twitter:title' content='From Twitter'>").title, "From Twitter")
        XCTAssertEqual(parse("<TITLE>\n  Plain   title\n</TITLE>").title, "Plain title")
        XCTAssertNil(parse("<p>nothing here</p>").title)
    }

    func testAttributeOrderQuotingAndCaseDoNotMatter() {
        XCTAssertEqual(parse("<META content=\"Reversed\" PROPERTY=\"OG:TITLE\">").title, "Reversed")
        XCTAssertEqual(parse("<meta property=og:title content=Bare>").title, "Bare")
    }

    func testEntitiesAreDecoded() {
        XCTAssertEqual(parse("<meta property='og:title' content='Tom &amp; Jerry &#8212; &#x41;&quot;'>").title, "Tom & Jerry — A\"")
        XCTAssertEqual(OpenGraphParser.decode("&unknown; &amp;"), "&unknown; &")
    }

    func testTheFirstOfARepeatedTagWins() {
        XCTAssertEqual(
            parse("<meta property='og:title' content='First'><meta property='og:title' content='Second'>").title, "First")
    }

    func testAnOverlongTitleIsCut() {
        let long = String(repeating: "x", count: 1000)
        XCTAssertEqual(parse("<title>\(long)</title>").title?.count, 300)
    }

    func testRelativeImageReferencesResolveAgainstThePage() {
        XCTAssertEqual(
            parse("<meta property='og:image' content='/img/a.png'>").imageURL?.absoluteString,
            "https://example.com/img/a.png")
        XCTAssertEqual(
            parse("<meta property='og:image' content='a.png'>").imageURL?.absoluteString,
            "https://example.com/news/a.png")
        XCTAssertEqual(
            parse("<meta property='og:image' content='//cdn.example.com/a.png'>").imageURL?.absoluteString,
            "https://cdn.example.com/a.png")
    }

    /// The image is fetched, so it may only be something fetchable.
    func testAnImageThatIsNotAWebAddressIsDropped() {
        for reference in ["data:image/png;base64,AAAA", "javascript:alert(1)", "file:///etc/hosts", "ftp://example.com/a.png", ""] {
            XCTAssertNil(parse("<meta property='og:image' content='\(reference)'>").imageURL, reference)
        }
    }
}

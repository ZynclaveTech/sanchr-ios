import Foundation
import XCTest

@testable import Sanchr

/// The jump-to-bottom button scrolled to an offset computed from estimated
/// row heights and landed short in long transcripts, so the button stayed.
final class ScrollToBottomTests: XCTestCase {

    func testAnAnimatedJumpTargetsTheLastItemAndSquaresUpAtTheEnd() throws {
        let vc = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Features/Chats/Presentation/MessageCollectionViewController.swift"),
            encoding: .utf8
        )
        let scroll = try XCTUnwrap(vc.range(of: "func scrollToBottom(animated: Bool) {"))
        let body = String(vc[scroll.upperBound...].prefix(1400))
        XCTAssertTrue(body.contains("collectionView.scrollToItem(at: lastIndexPath, at: .bottom, animated: true)"))
        let end = try XCTUnwrap(vc.range(of: "func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {"))
        let endBody = String(vc[end.upperBound...].prefix(500))
        XCTAssertTrue(endBody.contains("scrollToBottomImmediate()"))
        XCTAssertTrue(endBody.contains("onScrolledToBottom?(true)"))
    }
}

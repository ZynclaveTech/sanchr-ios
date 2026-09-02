import Foundation
import XCTest

@testable import Sanchr

/// Bubbles sized themselves against the whole screen. The host now
/// publishes its own width and republishes it when it changes.
final class BubbleWidthTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testBubblesReadTheHostWidth() throws {
        let bubble = try source("Features/Chats/Presentation/MessageBubble.swift")
        XCTAssertTrue(bubble.contains("@Environment(\\.messageAvailableWidth) private var availableWidth"))
        XCTAssertTrue(bubble.contains(".frame(maxWidth: bubbleMaxWidth,"))
        XCTAssertEqual(bubble.components(separatedBy: "UIScreen.main.bounds").count - 1, 1, "the screen is only the fallback")
    }

    func testTheHostPublishesAndRepublishesItsWidth() throws {
        let host = try source("Features/Chats/Presentation/MessageCollectionViewController.swift")
        XCTAssertTrue(host.contains(".environment(\\.messageAvailableWidth, self?.hostedWidth)"))
        let layout = try XCTUnwrap(host.range(of: "override func viewDidLayoutSubviews() {"))
        XCTAssertTrue(String(host[layout.upperBound...].prefix(200)).contains("republishHostedWidthIfChanged()"))
        XCTAssertTrue(host.contains("snapshot.reconfigureItems(snapshot.itemIdentifiers)"))
    }
}

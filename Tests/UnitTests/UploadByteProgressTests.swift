import XCTest
@testable import Sanchr
@testable import SanchrShared

/// The S3 PUT used the delegate-less `URLSession.upload`, so the only
/// progress the bubble ever saw was 0 and then 1: the ring never moved.
final class UploadByteProgressTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testDelegateMapsBytesToAFractionInOnePercentSteps() {
        final class Sink: @unchecked Sendable { var seen: [Double] = []; let lock = NSLock() }
        let sink = Sink()
        let delegate = UploadProgressDelegate { fraction in
            sink.lock.lock(); sink.seen.append(fraction); sink.lock.unlock()
        }
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.invalid")!)
        for sent in [Int64(5), 6, 7, 100, 105, 500, 999, 1000] {
            delegate.urlSession(URLSession.shared, task: task, didSendBodyData: 1,
                                totalBytesSent: sent, totalBytesExpectedToSend: 1000)
        }
        // 5 → reported (first), 6 and 7 dropped (< 1% further), 100 → 0.10,
        // 105 dropped, 500 → 0.5, 999 → 0.999, 1000 → 1.0 always.
        XCTAssertEqual(sink.seen, [0.005, 0.1, 0.5, 0.999, 1.0])
    }

    func testDelegateIgnoresUnknownTotals() {
        final class Sink: @unchecked Sendable { var count = 0 }
        let sink = Sink()
        let delegate = UploadProgressDelegate { _ in sink.count += 1 }
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.invalid")!)
        delegate.urlSession(URLSession.shared, task: task, didSendBodyData: 1, totalBytesSent: 1, totalBytesExpectedToSend: -1)
        XCTAssertEqual(sink.count, 0)
    }

    func testThePutFeedsTheRegisteredHandler() throws {
        let manager = try source("SanchrShared/Media/MediaUploadManager.swift")
        XCTAssertTrue(manager.contains("delegate: progressDelegate"), "the PUT must go through the progress delegate")
        XCTAssertTrue(manager.contains("setProgressHandler(progress, for: queued.id)"), "the adapter registers the caller's sink before execute")
        XCTAssertFalse(manager.contains("reports the terminal 0/1 progress points"), "stale comment")
    }

    func testEveryOutgoingAttachmentKindShowsTheRing() throws {
        XCTAssertTrue(try source("Features/Chats/Presentation/MediaBubbleImage.swift").contains("UploadRing(progress: progress)"))
        let bubble = try source("Features/Chats/Presentation/MessageBubble.swift")
        let doc = try XCTUnwrap(bubble.range(of: "case .document(let media):"))
        XCTAssertTrue(String(bubble[doc.upperBound...].prefix(900)).contains("UploadRing("), "documents get the ring too")
    }
}

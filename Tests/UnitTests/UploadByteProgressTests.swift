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

    /// A ring stayed on the bubble after the upload cleared: the reconfigure
    /// pass only revisited cells with an *active* upload, so the one that had
    /// just finished was never repainted. Seen in an on-screen render of the
    /// real transcript, not inferred.
    func testAFinishedUploadIsReconfiguredOnceMoreToRemoveItsRing() throws {
        let controller = try source("Features/Chats/Presentation/MessageCollectionViewController.swift")
        let fn = try XCTUnwrap(controller.range(of: "private func reconfigureUploadItems(uploads: UploadProgressStore) {"))
        let body = String(controller[fn.upperBound...].prefix(1400))
        XCTAssertTrue(body.contains("let affectedIds = activeIds.union(uploadIdsRenderedLastPass)"))
        XCTAssertTrue(body.contains("affectedIds.contains(item.message.id)"), "cells are matched against finished uploads too")
        XCTAssertFalse(body.contains("guard !activeIds.isEmpty else { return }"), "an empty active set must still clear the last ring")
    }

    func testEveryOutgoingAttachmentKindShowsTheRing() throws {
        XCTAssertTrue(try source("Features/Chats/Presentation/MediaBubbleImage.swift").contains("UploadRing(progress: progress)"))
        let bubble = try source("Features/Chats/Presentation/MessageBubble.swift")
        let doc = try XCTUnwrap(bubble.range(of: "case .document(let media):"))
        XCTAssertTrue(String(bubble[doc.upperBound...].prefix(900)).contains("UploadRing("), "documents get the ring too")
        // Albums were the one kind with no ring: the bubble dropped the
        // progress at both album call sites (photos, and video/mixed).
        XCTAssertTrue(try source("Features/Chats/Presentation/MediaAlbumBubble.swift").contains("UploadRing(progress: progress)"))
        let albumSites = bubble.components(separatedBy: "MediaAlbumBubble(\n").dropFirst()
        XCTAssertEqual(albumSites.count, 2)
        for site in albumSites {
            XCTAssertTrue(site.prefix(400).contains("uploadProgress: uploadProgress"), "an album call site drops the progress")
        }
    }
}

import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// Media the server or this device no longer has is told apart from a
/// download that merely failed: the bubble says it expired and asks for a
/// resend, instead of offering a retry that can only fail again.
final class MediaExpiredTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testExpiryHasItsOwnErrorAndWording() {
        XCTAssertNotEqual(AppError.mediaExpired, AppError.mediaDownloadFailed)
        XCTAssertEqual(AppError.mediaExpired.errorDescription, "This media is no longer available. Ask the sender to send it again.")
    }

    /// Gone from storage, refused by storage, or unreadable on this device.
    func testTheDownloaderClassifiesTheThreeGoneCases() throws {
        let manager = try source("Shared/Services/MediaDownloadManager.swift")
        XCTAssertTrue(manager.contains("catch let status as GRPCStatus where status.code == .notFound"))
        XCTAssertTrue(manager.contains("if [403, 404, 410].contains(status) {\n                throw AppError.mediaExpired"))
        let accessKey = try XCTUnwrap(manager.range(of: "guard let accessKey = try await store.getAndTouch(mediaId: mediaId) else {"))
        XCTAssertTrue(String(manager[accessKey.upperBound...].prefix(500)).contains("throw AppError.mediaExpired"))
    }

    func testTheBubbleShowsExpiredWithoutARetry() throws {
        let bubble = try source("Features/Chats/Presentation/MediaBubbleImage.swift")
        XCTAssertTrue(bubble.contains("} else if loadFailure == .expired {"))
        XCTAssertTrue(bubble.contains("Text(\"Media expired\")"))
        XCTAssertTrue(bubble.contains("Text(isOutgoing ? \"Send it again\" : \"Ask them to send it again\")"))
        XCTAssertTrue(bubble.contains("} else if loadFailure == .transient {"))
        XCTAssertTrue(bubble.contains("Self.expiredMessageIds.insert(messageId)"))
        XCTAssertFalse(bubble.contains("loadFailed"), "the boolean is replaced by the classified failure")
    }
}

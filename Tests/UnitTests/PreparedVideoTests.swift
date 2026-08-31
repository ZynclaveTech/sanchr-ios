import Foundation
import XCTest

@testable import Sanchr

/// Compressing a video once when it is sent to several conversations.
final class PreparedVideoTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - Wiring

    /// Compression stays inside `uploadAndRebuild`, where every send funnels
    /// through it. Moving it to the pick site once left one entry point
    /// covered and another silently not, and the comment there says so.
    func testCompressionStillHappensOnTheSendPath() throws {
        let body = code(try source("SanchrShared/Messaging/MessageSender.swift"))
        XCTAssertTrue(
            body.contains("compressed = await compressIfVideo(attachment, progress: progress)"),
            "a send that prepares nothing must still compress"
        )
    }

    /// Handing the file in transfers no ownership of it: deleting it after the
    /// first send would pull it out from under the rest.
    func testAPreparedFileIsNotDeletedByTheSendThatUsesIt() throws {
        let body = code(try source("SanchrShared/Messaging/MessageSender.swift"))
        XCTAssertTrue(body.contains("if ownsCompressedFile, compressed.isTemporary {"))
    }

    /// The forward path prepares once for the whole fan-out.
    func testForwardingPreparesOnceForAllDestinations() throws {
        let body = code(try source("Features/Chats/Presentation/ChatDetailViewModel+Send.swift"))
        let prepare = try XCTUnwrap(body.range(of: "messageSender.prepareVideoForReuse("))
        // Anchored on the argument, which appears only in the forward send.
        // Both "fanOut(targetConversationIds)" and "messageSender.sendMedia("
        // occur earlier in the file for other paths, and matching those made
        // this assertion compare the wrong pair.
        let fanOut = try XCTUnwrap(body.range(of: "prepared: prepared,"))
        XCTAssertTrue(
            prepare.lowerBound < fanOut.lowerBound,
            "preparing inside the fan-out compresses once per destination again"
        )
        XCTAssertTrue(body.contains("messageSender.discardPreparedVideo(prepared)"))
    }
}

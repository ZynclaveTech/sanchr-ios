import Foundation
import XCTest

@testable import Sanchr

/// Forwarding a message to one or more conversations.
@MainActor
final class ForwardMessageTests: XCTestCase {

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

    private var send: String {
        get throws { try source("Features/Chats/Presentation/ChatDetailViewModel+Send.swift") }
    }

    /// Forwarding media demanded `url.isFileURL` and otherwise said "Download
    /// the media first to forward it." On a received message that URL is
    /// remote whether or not the file is cached, so it asked even for a photo
    /// you were looking at — and nothing you could do would satisfy it.
    func testForwardingMediaResolvesItRatherThanRefusing() throws {
        let body = code(try send)
        XCTAssertFalse(
            body.contains("Download the media first to forward it."),
            "the app can resolve this itself; the demand had no way to be met"
        )
        XCTAssertTrue(
            body.contains("mediaResolver.decryptedURL("),
            "resolve through the same path that draws the bubble"
        )
    }

    /// Each forward waited for the last to encrypt and upload, so choosing
    /// three chats delivered three messages visibly apart.
    func testForwardsToSeveralChatsGoTogether() throws {
        let body = code(try send)
        XCTAssertTrue(body.contains("toConversationIds targetConversationIds: [String]"))
        XCTAssertTrue(
            body.contains("withTaskGroup"),
            "one send per destination, concurrently"
        )
    }

    /// The media is resolved before the fan-out, so three destinations do not
    /// each download the same file.
    func testTheMediaIsResolvedOnceForAllDestinations() throws {
        let body = code(try send)
        let resolve = try XCTUnwrap(body.range(of: "mediaResolver.decryptedURL("))
        let fanOut = try XCTUnwrap(body.range(of: "await fanOut(targetConversationIds) { target in\n                _ = try await messageSender.sendMedia"))
        XCTAssertTrue(
            resolve.lowerBound < fanOut.lowerBound,
            "resolving inside the fan-out downloads once per destination"
        )
    }

    // MARK: - The duplicate blocking path

    /// Blocking had two implementations that both called the same RPC. The UI
    /// used `ContactDataSource`; the repository's copy was reachable only from
    /// tests, and a second path to one feature is a second thing to keep right.
    func testThereIsOneBlockingImplementation() throws {
        let repo = code(try source("Shared/Repositories/ContactRepository.swift"))
        XCTAssertFalse(repo.contains("func blockUser("))
        XCTAssertFalse(repo.contains("func unblockUser("))
        XCTAssertFalse(repo.contains("func fetchBlockedUsers("))
    }
}

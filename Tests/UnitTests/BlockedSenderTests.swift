import Foundation
import XCTest

@testable import Sanchr

/// Whether a blocked contact can still reach you.
///
/// Blocking is enforced on the server in `route_message`, keyed on the sender.
/// A sealed message carries no sender the server can read — that is the point
/// of sealed sending — so for 1:1 chats, which use it whenever it is
/// available, the server cannot apply the block. The client is the only place
/// left, and it was not looking.
final class BlockedSenderTests: XCTestCase {

    private func cache(blocking blocked: Set<String> = []) -> PrivacySettingsCache {
        let cache = PrivacySettingsCache()
        cache.update(blockList: blocked)
        return cache
    }

    // MARK: - The decision

    func testAMessageFromABlockedSenderIsSuppressed() {
        let gate = MessagingPrivacyGate(privacySettings: cache(blocking: ["peer-1"]))
        XCTAssertEqual(gate.acceptsMessage(from: "peer-1"), .suppress)
    }

    func testAMessageFromAnyoneElseIsAllowed() {
        let gate = MessagingPrivacyGate(privacySettings: cache(blocking: ["peer-1"]))
        XCTAssertEqual(gate.acceptsMessage(from: "peer-2"), .allow)
    }

    func testNobodyBlockedAllowsEveryone() {
        let gate = MessagingPrivacyGate(privacySettings: cache())
        XCTAssertEqual(gate.acceptsMessage(from: "peer-1"), .allow)
    }

    // MARK: - Keeping the list current

    /// The block list was fetched only to be displayed on the blocked-contacts
    /// screen and never written to the cache, so the set the gate consults was
    /// empty for the entire session and nothing was ever blocked.
    func testTheCacheCanBeUpdatedForOneContact() {
        let cache = self.cache()
        XCTAssertFalse(cache.isBlocked("peer-1"))

        cache.setBlocked("peer-1", true)
        XCTAssertTrue(cache.isBlocked("peer-1"))

        cache.setBlocked("peer-1", false)
        XCTAssertFalse(cache.isBlocked("peer-1"))
    }

    /// Blocking during a session has to take effect during that session.
    func testBlockingOneContactLeavesTheRestAlone() {
        let cache = self.cache(blocking: ["peer-1"])
        cache.setBlocked("peer-2", true)
        XCTAssertTrue(cache.isBlocked("peer-1"))
        XCTAssertTrue(cache.isBlocked("peer-2"))
    }

    // MARK: - Wiring

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

    /// The decision is worthless unless something consults it, and unless the
    /// list it reads is ever filled. Both were true before this change.
    func testTheSealedReceivePathConsultsTheGate() throws {
        let repo = code(try source("Shared/Repositories/MessageRepository.swift"))
        XCTAssertTrue(
            repo.contains("privacyGate.acceptsMessage(from: effectiveSenderId)"),
            "the sender is only knowable after decryption; that is where the check belongs"
        )
        XCTAssertTrue(
            repo.contains("case dropped(reason: String)"),
            "a deliberate discard is not an undeliverable envelope to be healed and retried"
        )
    }

    func testTheBlockListIsBroughtUpToDateOnLaunch() throws {
        XCTAssertTrue(
            try code(source("App/SanchrApp.swift")).contains("blockList.replace(withServerList:"),
            "the stored list is only as good as the last time the server's was taken"
        )
    }

    /// The first messages of a launch are the ones a blocked person sent
    /// while this phone was away. The list has to be there before them.
    func testTheStoredListIsReadBeforeAMessageIsJudged() throws {
        let repo = code(try source("Shared/Repositories/MessageRepository.swift"))
        let load = try XCTUnwrap(repo.range(of: "await loadBlockList()"))
        let judge = try XCTUnwrap(repo.range(of: "privacyGate.acceptsMessage(from: effectiveSenderId)"))
        XCTAssertLessThan(load.lowerBound, judge.lowerBound)

        let container = code(try source("App/DependencyContainer.swift"))
        XCTAssertEqual(
            container.components(separatedBy: "loadBlockList: { await blockList.ensureLoaded() }").count - 1,
            2,
            "both places that build the repository must hand it the list"
        )
    }

    /// A block or unblock made on a screen has to reach the stored list, or
    /// it lasts only until the app is closed.
    func testEveryScreenThatBlocksWritesThroughTheStoredList() throws {
        for path in [
            "Features/Settings/Presentation/BlockedContactsView.swift",
            "Features/Contacts/Presentation/ContactsView.swift",
            "Features/Chats/Presentation/ConversationInfoView.swift",
        ] {
            let text = code(try source(path))
            XCTAssertTrue(text.contains("container.blockList.setBlocked("), path)
            XCTAssertFalse(text.contains("privacySettings.setBlocked("), path)
        }
    }
}

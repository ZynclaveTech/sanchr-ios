import XCTest

@testable import Sanchr

/// Deleting a message removes what it had put on disk.
///
/// A photo that has been opened sits decrypted in the cache under its
/// message's id. Delete Message removed the row and left that file; only
/// view-once, clearing a chat and expiry cleaned up after themselves.
final class DeleteMessageMediaTests: XCTestCase {

    private func repository() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Shared/Repositories/MessageRepository.swift"),
            encoding: .utf8
        )
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    }

    /// The body of the function starting at `signature`, up to the next
    /// function at the same indentation.
    private func body(of signature: String, in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: signature))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    func ")?.lowerBound
            ?? rest.range(of: "\n    private func ")?.lowerBound
            ?? rest.endIndex
        return rest[..<end]
    }

    func testDeletingAMessageRemovesItsCachedFileBeforeAndAfterItsRow() throws {
        let body = try body(of: "func deleteMessage(id: String, forEveryone: Bool) async throws {", in: repository())
        let removals = body.ranges(of: "mediaDownloadManager.removeCachedFile(messageId: id)")
        let row = try XCTUnwrap(body.range(of: "localDatabase.deleteMessage(id: id)"))

        XCTAssertEqual(removals.count, 2)
        // Before: the only pass that runs if the app dies in between.
        XCTAssertLessThan(try XCTUnwrap(removals.first).lowerBound, row.lowerBound)
        // After: a chat that is open can fetch the picture again in between.
        XCTAssertGreaterThan(try XCTUnwrap(removals.last).lowerBound, row.lowerBound)
    }

    /// Moved into the vault, the chat's own decrypted copy must not stay
    /// behind in the cache.
    func testAutoVaultingRemovesTheChatsCachedCopy() throws {
        let source = try repository()
        let tombstone = try XCTUnwrap(source.range(of: "content: .system(.autoVaulted)"))
        let after = source[tombstone.upperBound...]
        let nextFunction = after.range(of: "\n    private func ")?.lowerBound ?? after.endIndex

        XCTAssertTrue(
            after[..<nextFunction].contains("mediaDownloadManager.removeCachedFile(messageId: message.id)"))
    }
}

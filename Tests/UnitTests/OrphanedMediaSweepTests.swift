import SanchrShared
import XCTest

@testable import Sanchr

/// A stored photo whose message is gone is removed; anything the sweep is
/// unsure of is left.
final class OrphanedMediaSweepTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let kept = "0F8FAD5B-D9CB-469F-A165-70867728950E"
    private let gone = "7c9e6679-7425-40de-944b-e07fc1f90ae7"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphans-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func file(_ name: String, age: TimeInterval = OrphanedMediaSweep.minimumAge) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func sweep(existing: Set<String>) async -> Set<String> {
        await OrphanedMediaSweep.sweep(directory: directory, now: now) { ids in existing.intersection(ids) }
    }

    func testAFileWhoseMessageIsGoneIsRemovedAndOneWhoseMessageIsHereIsNot() async throws {
        let orphan = try file("\(gone).jpg")
        let live = try file("\(kept).jpg")

        let removed = await sweep(existing: [kept])

        XCTAssertEqual(removed, [gone])
        XCTAssertFalse(exists(orphan))
        XCTAssertTrue(exists(live))
    }

    func testAlbumTilesGoWithTheirMessage() async throws {
        let tile = try file("\(gone)#2.mp4")
        let liveTile = try file("\(kept)#0.jpg")

        await sweep(existing: [kept])

        XCTAssertFalse(exists(tile))
        XCTAssertTrue(exists(liveTile))
    }

    /// Something being sent or saved right now may not have its row, or its
    /// final id, yet.
    func testARecentFileIsLeftAloneWhateverTheDatabaseSays() async throws {
        let fresh = try file("\(gone).jpg", age: OrphanedMediaSweep.minimumAge - 1)

        let removed = await sweep(existing: [])

        XCTAssertEqual(removed, [])
        XCTAssertTrue(exists(fresh))
    }

    func testAFileWhoseNameDoesNotGiveAMessageIdIsLeftAlone() async throws {
        let hashed = try file(String(repeating: "a", count: 64) + ".jpg")
        let other = try file("thumbs.db")
        let hidden = try file(".nomedia")

        let removed = await sweep(existing: [])

        XCTAssertEqual(removed, [])
        XCTAssertTrue(exists(hashed) && exists(other) && exists(hidden))
    }

    func testADatabaseThatCannotAnswerRemovesNothing() async throws {
        let orphan = try file("\(gone).jpg")

        let removed = await OrphanedMediaSweep.sweep(directory: directory, now: now) { _ in
            throw NSError(domain: "test", code: 1)
        }

        XCTAssertEqual(removed, [])
        XCTAssertTrue(exists(orphan))
    }

    func testAMissingDirectoryIsNotAnError() async {
        let nowhere = directory.appendingPathComponent("nope")
        let removed = await OrphanedMediaSweep.sweep(directory: nowhere, now: now) { _ in [] }
        XCTAssertEqual(removed, [])
    }

    func testAFileNameIsReadBackToTheMessageItWasStoredFor() {
        XCTAssertEqual(OrphanedMediaSweep.messageId(fromFileName: "\(kept).jpg"), kept)
        XCTAssertEqual(OrphanedMediaSweep.messageId(fromFileName: "\(kept)#3.mp4"), kept)
        XCTAssertEqual(OrphanedMediaSweep.messageId(fromFileName: kept), kept)
        XCTAssertNil(OrphanedMediaSweep.messageId(fromFileName: String(repeating: "a", count: 64) + ".jpg"))
        XCTAssertNil(OrphanedMediaSweep.messageId(fromFileName: ".nomedia"))
        XCTAssertNil(OrphanedMediaSweep.messageId(fromFileName: "not an id.jpg"))
    }

    func testReadingANameBackAgreesWithHowTheNameWasMade() {
        for id in [kept, "\(kept)#0", "\(kept)#12"] {
            let name = MediaCacheFile.fileName(messageId: id, mimeType: "image/jpeg")
            XCTAssertEqual(OrphanedMediaSweep.messageId(fromFileName: name), kept, name)
        }
    }

    // MARK: - What the database is asked

    func testTheDatabaseSaysWhichMessagesItHolds() async throws {
        let db = try LocalDatabase(
            path: FileManager.default.temporaryDirectory.appendingPathComponent("orph-\(UUID().uuidString).sqlite"),
            passphraseProvider: { "unit-test-passphrase" }
        )
        try await db.saveConversation(
            Conversation(
                id: "c1", participants: [], unreadCount: 0, isPinned: false, isMuted: false, isArchived: false,
                type: .oneToOne, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
            )
        )
        try await db.saveMessage(
            Message(
                id: kept, conversationId: "c1", senderId: "peer", timestamp: Date(timeIntervalSince1970: 2),
                content: .text("hi"), status: .delivered, isOutgoing: false
            )
        )

        let found = try await db.fetchExistingMessageIds(among: [kept, gone])
        let none = try await db.fetchExistingMessageIds(among: [])

        XCTAssertEqual(found, [kept])
        XCTAssertEqual(none, [])
    }

    /// A stand-in that knows nothing must say "it exists": the answer decides
    /// what is deleted.
    func testAStandInDatabaseNeverCausesADelete() async throws {
        let standIn = UnavailableLocalDatabase(error: NSError(domain: "test", code: 1))
        do {
            _ = try await standIn.fetchExistingMessageIds(among: [gone])
            XCTFail("an unavailable database must throw, so nothing is removed")
        } catch {}
    }
}

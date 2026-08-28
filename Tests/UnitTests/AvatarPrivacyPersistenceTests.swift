import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// A contact who sets profile-photo visibility to "nobody" must stop showing a
/// photo here. The server withholds it correctly; the bug was that the local
/// upsert put the previously cached one back, so the setting was enforced and
/// then quietly undone. It regressed twice, hence these.
final class AvatarPrivacyPersistenceTests: XCTestCase {

    private func makeDatabase() throws -> LocalDatabase {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("avatar-privacy-\(UUID().uuidString).sqlite").path
        return try LocalDatabase(path: path, passphraseProvider: { "unit-test-passphrase" })
    }

    private func user(
        id: String = "peer-1",
        displayName: String,
        avatar: String?
    ) -> User {
        User(
            id: id,
            phoneNumber: "+15550001111",
            displayName: displayName,
            avatarURL: avatar.flatMap(URL.init(string:)),
            bio: nil,
            isVerified: false,
            lastSeen: nil,
            identityKeyFingerprint: nil,
            status: .offline
        )
    }

    private func storedAvatar(_ db: LocalDatabase, id: String = "peer-1") async throws -> URL? {
        try await db.fetchContacts().first(where: { $0.id == id })?.avatarURL
    }

    /// The regression itself: once the server stops sending an avatar, the
    /// cached one must not come back on the next sync.
    func testWithheldAvatarIsNotRestoredFromCache() async throws {
        let db = try makeDatabase()

        // A previous sync, while the photo was still public.
        try await db.saveContact(
            user(displayName: "Alice", avatar: "https://cdn.example.com/alice.jpg")
        )
        let before = try await storedAvatar(db)
        XCTAssertNotNil(before, "precondition: the avatar was cached")

        // The owner sets visibility to "nobody". The server now returns the
        // E2EE placeholder name and no avatar at all.
        try await db.saveContact(
            user(displayName: User.serverPlaceholderDisplayName, avatar: nil)
        )

        let after = try await storedAvatar(db)
        XCTAssertNil(after, "a withheld avatar must not be restored from the local cache")
    }

    /// The behaviour that must survive the fix: the server sends "Sanchr User"
    /// for every account because names are E2EE, so a locally resolved name
    /// still has to win. Only the avatar changed.
    func testResolvedDisplayNameIsStillPreserved() async throws {
        let db = try makeDatabase()

        try await db.saveContact(user(displayName: "Alice", avatar: nil))
        try await db.saveContact(
            user(displayName: User.serverPlaceholderDisplayName, avatar: nil)
        )

        let stored = try await db.fetchContacts().first(where: { $0.id == "peer-1" })
        XCTAssertEqual(stored?.displayName, "Alice", "the placeholder must not clobber a real name")
    }

    /// A real incoming name still wins outright.
    func testRealIncomingNameOverwrites() async throws {
        let db = try makeDatabase()

        try await db.saveContact(user(displayName: "Alice", avatar: nil))
        try await db.saveContact(user(displayName: "Alice Smith", avatar: nil))

        let stored = try await db.fetchContacts().first(where: { $0.id == "peer-1" })
        XCTAssertEqual(stored?.displayName, "Alice Smith")
    }

    /// Turning the photo back on must show it again — the fix must not make
    /// avatars permanently unsettable.
    func testAvatarReappearsWhenTheServerSendsItAgain() async throws {
        let db = try makeDatabase()

        try await db.saveContact(
            user(displayName: User.serverPlaceholderDisplayName, avatar: nil)
        )
        try await db.saveContact(
            user(
                displayName: User.serverPlaceholderDisplayName,
                avatar: "https://cdn.example.com/alice-2.jpg"
            )
        )

        let after = try await storedAvatar(db)
        XCTAssertEqual(after?.absoluteString, "https://cdn.example.com/alice-2.jpg")
    }
}

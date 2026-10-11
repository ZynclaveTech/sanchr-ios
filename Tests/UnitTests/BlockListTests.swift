import SanchrShared
import XCTest

@testable import Sanchr

/// The block list is stored, so it is there before the first message of a
/// launch — and there at all when the server cannot be reached.
final class BlockListTests: XCTestCase {

    private func gate(_ cache: PrivacySettingsCache) -> MessagingPrivacyGate {
        MessagingPrivacyGate(privacySettings: cache)
    }

    /// The launch this is for: the app was closed, a blocked person wrote,
    /// and their message is the first thing to arrive.
    func testABlockMadeInOneLaunchIsEnforcedAtTheStartOfTheNext() async throws {
        let database = try InMemoryLocalDatabase.make()
        await BlockList(localDatabase: database, cache: PrivacySettingsCache()).setBlocked("peer-1", true)

        let nextLaunch = PrivacySettingsCache()
        XCTAssertEqual(gate(nextLaunch).acceptsMessage(from: "peer-1"), .allow, "memory alone starts empty")

        await BlockList(localDatabase: database, cache: nextLaunch).ensureLoaded()

        XCTAssertEqual(gate(nextLaunch).acceptsMessage(from: "peer-1"), .suppress)
        XCTAssertEqual(gate(nextLaunch).acceptsMessage(from: "peer-2"), .allow)
    }

    func testAnUnblockIsRememberedToo() async throws {
        let database = try InMemoryLocalDatabase.make()
        let first = BlockList(localDatabase: database, cache: PrivacySettingsCache())
        await first.setBlocked("peer-1", true)
        await first.setBlocked("peer-1", false)

        let nextLaunch = PrivacySettingsCache()
        await BlockList(localDatabase: database, cache: nextLaunch).ensureLoaded()

        XCTAssertFalse(nextLaunch.isBlocked("peer-1"))
    }

    func testTheServersListReplacesWhatWasHeldAndWhatWasStored() async throws {
        let database = try InMemoryLocalDatabase.make()
        let cache = PrivacySettingsCache()
        let list = BlockList(localDatabase: database, cache: cache)
        await list.setBlocked("unblocked-elsewhere", true)

        await list.replace(withServerList: ["peer-1", "peer-2"])

        XCTAssertEqual(cache.blockedUserIds, ["peer-1", "peer-2"])
        let stored = try await database.fetchBlockedUserIds()
        XCTAssertEqual(stored, ["peer-1", "peer-2"])
    }

    /// The stored copy is the older of the two. Read late, it must not undo
    /// the server's.
    func testAStoredListReadAfterTheServersDoesNotOverwriteIt() async throws {
        let database = try InMemoryLocalDatabase.make()
        try await database.replaceBlockedUserIds(["stale"])
        let cache = PrivacySettingsCache()
        let list = BlockList(localDatabase: database, cache: cache)

        await list.replace(withServerList: ["fresh"])
        await list.ensureLoaded()

        XCTAssertEqual(cache.blockedUserIds, ["fresh"])
    }

    func testLoadingIsDoneOnceALaunch() async throws {
        let database = try InMemoryLocalDatabase.make()
        try await database.replaceBlockedUserIds(["peer-1"])
        let cache = PrivacySettingsCache()
        let list = BlockList(localDatabase: database, cache: cache)
        await list.ensureLoaded()

        // Changed behind its back: a second load would pick this up.
        try await database.replaceBlockedUserIds(["someone-else"])
        await list.ensureLoaded()

        XCTAssertEqual(cache.blockedUserIds, ["peer-1"])
    }

    func testBlockingTheSamePersonTwiceKeepsOneRecord() async throws {
        let database = try InMemoryLocalDatabase.make()
        let list = BlockList(localDatabase: database, cache: PrivacySettingsCache())

        await list.setBlocked("peer-1", true)
        await list.setBlocked("peer-1", true)

        let stored = try await database.fetchBlockedUserIds()
        XCTAssertEqual(stored, ["peer-1"])
    }

    /// A block made before anything was loaded must not lose the rest of
    /// the stored list when it is.
    func testABlockMadeBeforeTheListWasReadKeepsTheOthers() async throws {
        let database = try InMemoryLocalDatabase.make()
        try await database.replaceBlockedUserIds(["already"])
        let cache = PrivacySettingsCache()

        await BlockList(localDatabase: database, cache: cache).setBlocked("new", true)

        XCTAssertEqual(cache.blockedUserIds, ["already", "new"])
    }

    /// A database that cannot be read or written must not take the list in
    /// memory down with it: the server's copy still applies for the session.
    func testWithoutADatabaseTheServersListStillApplies() async {
        let database = UnavailableLocalDatabase(error: NSError(domain: "test", code: 1))
        let cache = PrivacySettingsCache()
        let list = BlockList(localDatabase: database, cache: cache)

        await list.ensureLoaded()
        XCTAssertTrue(cache.blockedUserIds.isEmpty)

        await list.replace(withServerList: ["peer-1"])
        await list.setBlocked("peer-2", true)

        XCTAssertEqual(cache.blockedUserIds, ["peer-1", "peer-2"])
    }
}

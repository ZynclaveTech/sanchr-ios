import LibSignalClient
import XCTest
@testable import SanchrShared
@testable import Sanchr

/// The record that stops a first message sent without a one-time pre-key from
/// being accepted twice.
final class SeenBaseKeysTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("seen.json") }
    private let held: (UInt32) -> Bool = { _ in true }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("seen-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func key(_ byte: UInt8) -> Data { Data(repeating: byte, count: 33) }

    private func saved() throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
    }

    func testABaseKeyIsAcceptedOnceForAPairOfPreKeys() throws {
        let seen = SeenBaseKeys(fileURL: file)

        XCTAssertTrue(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7), isHeld: held))
        XCTAssertFalse(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7), isHeld: held))
        // A different message, or the same base key against other pre-keys, is not a reuse.
        XCTAssertTrue(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(8), isHeld: held))
        XCTAssertTrue(try seen.insert(kyberPreKeyId: 9, signedPreKeyId: 2, baseKey: key(7), isHeld: held))
        XCTAssertTrue(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 9, baseKey: key(7), isHeld: held))
    }

    /// A replay after a restart is the case that matters: the session may be
    /// gone, and so is anything kept only in memory.
    func testItIsRememberedAcrossARestart() throws {
        XCTAssertTrue(
            try SeenBaseKeys(fileURL: file).insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7), isHeld: held))

        XCTAssertFalse(
            try SeenBaseKeys(fileURL: file).insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7), isHeld: held))
    }

    /// Two readers of one file — the app and an extension — each see what the
    /// other recorded, rather than overwriting it from a stale copy.
    func testWhatAnotherInstanceRecordedIsSeenAndKept() throws {
        let app = SeenBaseKeys(fileURL: file)
        let ext = SeenBaseKeys(fileURL: file)

        XCTAssertTrue(try app.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(1), isHeld: held))
        XCTAssertTrue(try ext.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(2), isHeld: held))

        XCTAssertFalse(try app.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(2), isHeld: held))
        XCTAssertFalse(try ext.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(1), isHeld: held))
        XCTAssertEqual(try saved().count, 2)
    }

    /// Making room by forgetting the oldest would let anyone able to start
    /// sessions push a live entry out and replay what it stood for.
    func testAFullKeyRefusesNewMessagesAndForgetsNothing() throws {
        let seen = SeenBaseKeys(fileURL: file, limitPerKey: 3)
        for byte in UInt8(1)...3 {
            XCTAssertTrue(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 1, baseKey: key(byte), isHeld: held))
        }

        XCTAssertThrowsError(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 1, baseKey: key(4), isHeld: held)) {
            XCTAssertEqual($0 as? SeenBaseKeys.RecordError, .full)
        }
        // Every one of the first three is still refused.
        for byte in UInt8(1)...3 {
            XCTAssertFalse(
                try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 1, baseKey: key(byte), isHeld: held), "\(byte)")
        }
        // The limit is per key: another key still has room.
        XCTAssertTrue(try seen.insert(kyberPreKeyId: 2, signedPreKeyId: 1, baseKey: key(4), isHeld: held))
    }

    func testEntriesGoWhenTheKeyTheyBelongToDoesAndNotBefore() throws {
        let seen = SeenBaseKeys(fileURL: file)
        XCTAssertTrue(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 1, baseKey: key(1), isHeld: held))
        XCTAssertTrue(try seen.insert(kyberPreKeyId: 2, signedPreKeyId: 1, baseKey: key(2), isHeld: held))

        // Key 1 has been rotated away; key 2 is still held.
        XCTAssertTrue(try seen.insert(kyberPreKeyId: 3, signedPreKeyId: 1, baseKey: key(3)) { $0 != 1 })

        let ids = try saved().map { $0.split(separator: ":")[0] }
        XCTAssertEqual(ids, ["2", "3"])
    }

    /// What cannot be durably remembered is not accepted.
    func testAMessageIsRefusedWhenTheRecordCannotBeSaved() throws {
        let blocker = directory.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker)
        let seen = SeenBaseKeys(fileURL: blocker.appendingPathComponent("seen.json"))

        XCTAssertThrowsError(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7), isHeld: held))
    }

    /// A record that is there but cannot be understood is not an empty one:
    /// starting over would accept everything it had ever refused.
    func testAnUnreadableRecordRefusesRatherThanStartingOver() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let seen = SeenBaseKeys(fileURL: file)

        XCTAssertThrowsError(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7), isHeld: held)) {
            XCTAssertEqual($0 as? SeenBaseKeys.RecordError, .unreadable)
        }
        // And it is left as it was, not overwritten.
        XCTAssertEqual(try Data(contentsOf: file), Data("not json".utf8))
    }

    func testTheKyberStoreRefusesABaseKeyItHasSeen() throws {
        let store = SanchrKyberPreKeyStore(userId: "u", keychain: MockKeychainService(), baseDirectory: directory)
        let baseKey = PrivateKey.generate().publicKey
        let context = LibSignalClient.NullContext()

        XCTAssertNoThrow(try store.markKyberPreKeyUsed(id: 1, signedPreKeyId: 2, baseKey: baseKey, context: context))
        XCTAssertThrowsError(try store.markKyberPreKeyUsed(id: 1, signedPreKeyId: 2, baseKey: baseKey, context: context))
        // And a new store over the same directory remembers.
        let reopened = SanchrKyberPreKeyStore(userId: "u", keychain: MockKeychainService(), baseDirectory: directory)
        XCTAssertThrowsError(try reopened.markKyberPreKeyUsed(id: 1, signedPreKeyId: 2, baseKey: baseKey, context: context))
    }
}

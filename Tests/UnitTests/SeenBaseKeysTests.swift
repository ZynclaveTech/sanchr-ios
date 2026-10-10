import LibSignalClient
import XCTest
@testable import SanchrShared
@testable import Sanchr

/// The record that stops a first message sent without a one-time pre-key from
/// being accepted twice.
final class SeenBaseKeysTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("seen.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("seen-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func key(_ byte: UInt8) -> Data { Data(repeating: byte, count: 33) }

    func testABaseKeyIsAcceptedOnceForAPairOfPreKeys() throws {
        let seen = SeenBaseKeys(fileURL: file)

        XCTAssertTrue(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7)))
        XCTAssertFalse(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7)))
        // A different message, or the same base key against other pre-keys, is not a reuse.
        XCTAssertTrue(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(8)))
        XCTAssertTrue(try seen.insert(kyberPreKeyId: 9, signedPreKeyId: 2, baseKey: key(7)))
        XCTAssertTrue(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 9, baseKey: key(7)))
    }

    /// A replay after a restart is the case that matters: the session may be
    /// gone, and so is anything kept only in memory.
    func testItIsRememberedAcrossARestart() throws {
        XCTAssertTrue(try SeenBaseKeys(fileURL: file).insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7)))

        XCTAssertFalse(try SeenBaseKeys(fileURL: file).insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7)))
    }

    func testItDoesNotGrowWithoutLimitAndForgetsTheOldestFirst() throws {
        let seen = SeenBaseKeys(fileURL: file, limit: 3)
        for byte in UInt8(1)...4 {
            XCTAssertTrue(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 1, baseKey: key(byte)))
        }

        let saved = try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.count, 3)
        // The newest three are still refused; only the oldest was let go.
        for byte in UInt8(2)...4 {
            XCTAssertFalse(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 1, baseKey: key(byte)), "\(byte)")
        }
    }

    /// What cannot be durably remembered is not accepted.
    func testAMessageIsRefusedWhenTheRecordCannotBeSaved() throws {
        let blocker = directory.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker)
        let seen = SeenBaseKeys(fileURL: blocker.appendingPathComponent("seen.json"))

        XCTAssertThrowsError(try seen.insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7)))
    }

    func testACorruptFileIsStartedOverRatherThanTrusted() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)

        XCTAssertTrue(try SeenBaseKeys(fileURL: file).insert(kyberPreKeyId: 1, signedPreKeyId: 2, baseKey: key(7)))
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

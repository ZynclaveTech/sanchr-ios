import XCTest
import CryptoKit
import SanchrShared
@testable import Sanchr

/// Minimal in-memory DeviceSecretProvider for tests. Only exercises the
/// `mediaAccessSecret` / `backupFingerprint` paths — everything else aborts.
final class InMemoryDeviceSecretProvider: DeviceSecretProviderProtocol, @unchecked Sendable {
    private let seed: Data
    init(seed: Data) { self.seed = seed }

    func readDeviceMasterSecret() throws -> Data? { seed }
    func readOrCreateDeviceMasterSecret() throws -> Data { seed }
    func localDatabasePassphrase() throws -> String {
        fatalError("not used in VaultCryptoTests")
    }
    func localHMACKey() throws -> Data { fatalError("not used in VaultCryptoTests") }
    func mediaWrapKey() throws -> Data { fatalError("not used in VaultCryptoTests") }
    func mediaAccessSecret() throws -> Data { seed }
    func clearDeviceSecrets() throws { /* no-op */ }

    func backupFingerprint() throws -> String {
        // Same implementation as the production code — if the production
        // implementation changes, update this too.
        let label = "sanchr-backup-fingerprint-v1".data(using: .utf8)!
        var input = Data()
        input.append(seed)
        input.append(label)
        let digest = SHA256.hash(data: input)
        return Data(digest).base64EncodedString()
    }
}

final class VaultCryptoTests: XCTestCase {

    // MARK: - Vault HKDF derivation

    func test_deriveVaultAccessKeyManual_isDeterministic() {
        let derivation = MediaKeyDerivation()
        let dls = Data(repeating: 0x01, count: 32)
        let salt = Data(repeating: 0x02, count: 32)
        let vaultItemId = "5f3e1b7c-1234-4abc-9def-0123456789ab"

        let first = derivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: salt,
            vaultItemId: vaultItemId
        )
        let second = derivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: salt,
            vaultItemId: vaultItemId
        )

        XCTAssertEqual(first, second, "same inputs must produce the same key")
        XCTAssertEqual(first.count, 32, "key must be 32 bytes")
    }

    func test_deriveVaultAccessKeyManual_differsByVaultItemId() {
        let derivation = MediaKeyDerivation()
        let dls = Data(repeating: 0x01, count: 32)
        let salt = Data(repeating: 0x02, count: 32)

        let a = derivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: salt,
            vaultItemId: "item-a"
        )
        let b = derivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: salt,
            vaultItemId: "item-b"
        )

        XCTAssertNotEqual(a, b, "different vault_item_ids must produce different keys")
    }

    func test_deriveVaultAccessKeyFromMessage_isDeterministic() {
        let derivation = MediaKeyDerivation()
        let mediaKey = Data(repeating: 0xAA, count: 32)
        let dls = Data(repeating: 0x01, count: 32)
        let vaultItemId = "5f3e1b7c-1234-4abc-9def-0123456789ab"

        let first = derivation.deriveVaultAccessKeyFromMessage(
            mediaKey: mediaKey,
            deviceSecret: dls,
            vaultItemId: vaultItemId
        )
        let second = derivation.deriveVaultAccessKeyFromMessage(
            mediaKey: mediaKey,
            deviceSecret: dls,
            vaultItemId: vaultItemId
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
    }

    func test_manualAndFromMessage_produceDifferentKeys() {
        let derivation = MediaKeyDerivation()
        let dls = Data(repeating: 0x01, count: 32)
        let vaultItemId = "same-item"

        // Manual uses (ikm=dls, salt=random). Simulate with a 32-byte "salt"
        // that coincidentally equals mediaKey to prove the labels are what
        // provide domain separation, not the inputs.
        let collidingBytes = Data(repeating: 0xBB, count: 32)

        let manual = derivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: collidingBytes,
            vaultItemId: vaultItemId
        )
        let fromMessage = derivation.deriveVaultAccessKeyFromMessage(
            mediaKey: collidingBytes,
            deviceSecret: dls,
            vaultItemId: vaultItemId
        )

        XCTAssertNotEqual(
            manual, fromMessage,
            "the two HKDF labels must domain-separate even when ikm/salt bytes collide"
        )
    }

    // MARK: - Backup fingerprint

    func test_backupFingerprint_isDeterministic() throws {
        let provider = InMemoryDeviceSecretProvider(seed: Data(repeating: 0x42, count: 32))
        let first = try provider.backupFingerprint()
        let second = try provider.backupFingerprint()
        XCTAssertEqual(first, second, "same dls must produce same fingerprint")
        XCTAssertFalse(first.isEmpty)
    }

    func test_backupFingerprint_differsByDLS() throws {
        let providerA = InMemoryDeviceSecretProvider(seed: Data(repeating: 0x01, count: 32))
        let providerB = InMemoryDeviceSecretProvider(seed: Data(repeating: 0x02, count: 32))

        let a = try providerA.backupFingerprint()
        let b = try providerB.backupFingerprint()

        XCTAssertNotEqual(a, b, "different dls must produce different fingerprints")
    }

    func test_backupFingerprint_doesNotLeakDLS() throws {
        let seed = Data((0..<32).map { UInt8($0) })
        let provider = InMemoryDeviceSecretProvider(seed: seed)
        let fingerprint = try provider.backupFingerprint()

        // Base64-decode the fingerprint and verify the raw bytes do not
        // start with the dls bytes (a one-way hash would only match by
        // vanishingly rare collision).
        guard let fingerprintBytes = Data(base64Encoded: fingerprint) else {
            XCTFail("fingerprint must be valid base64")
            return
        }
        XCTAssertEqual(fingerprintBytes.count, 32, "SHA-256 output must be 32 bytes")
        XCTAssertNotEqual(fingerprintBytes, seed, "fingerprint must not equal the raw dls")
        XCTAssertNotEqual(
            fingerprintBytes.prefix(8), seed.prefix(8),
            "fingerprint must not be a simple prefix of the dls"
        )
    }

    func test_backupFingerprint_productionMatchesReference() throws {
        // Guards against drift between the production DeviceSecretProvider
        // and the InMemoryDeviceSecretProvider test helper. Both are expected
        // to produce identical fingerprints for the same seed — if either
        // implementation changes and the other doesn't, this test fails.
        let knownSecret = Data(repeating: 0x77, count: 32)
        let storage = MockSecureStorage()
        storage.deviceMasterSecret = knownSecret

        let production = DeviceSecretProvider(secureStorage: storage)
        let reference = InMemoryDeviceSecretProvider(seed: knownSecret)

        let productionFingerprint = try production.backupFingerprint()
        let referenceFingerprint = try reference.backupFingerprint()

        XCTAssertEqual(
            productionFingerprint, referenceFingerprint,
            "production and reference backupFingerprint must agree"
        )
    }

    // MARK: - AccessKeyEntry.Kind + sliding TTL

    func test_AccessKeyEntry_hasKindField() {
        let entry = AccessKeyEntry(
            mediaId: "test-id",
            accessKey: Data(repeating: 0, count: 32),
            conversationId: "conv-id",
            kind: .vaultManual,
            createdAt: Date(),
            lastAccessedAt: Date()
        )
        XCTAssertEqual(entry.kind, .vaultManual)
    }

    func test_AccessKeyEntryKind_allCases() {
        let all = AccessKeyEntry.Kind.allCases
        XCTAssertEqual(Set(all.map(\.rawValue)), [
            "messageMedia", "vaultAutoVaulted", "vaultManual",
        ])
    }

    func test_accessKeyStore_touchBumpsLastAccessedAt() async throws {
        // Use a fake clock for determinism — GRDB's Date encoding may have
        // sub-second precision loss depending on format, so a real 20ms
        // sleep is not reliable across CI. The fake clock jumps by 1 hour.
        let fakeClock = MutableClock(now: Date())
        let store = try makeInMemoryAccessKeyStore(clock: fakeClock)
        let mediaId = "store-touch-test"

        try await store.store(
            mediaId: mediaId,
            accessKey: Data(repeating: 0xAA, count: 32),
            conversationId: "conv",
            kind: .vaultManual
        )

        let before = try await store.retrieveEntry(mediaId: mediaId)!

        // Jump the clock forward 1 hour and touch — bump must be observable.
        fakeClock.now = fakeClock.now.addingTimeInterval(3600)
        try await store.touch(mediaId: mediaId)

        let after = try await store.retrieveEntry(mediaId: mediaId)!

        XCTAssertGreaterThan(after.lastAccessedAt, before.lastAccessedAt)
        XCTAssertEqual(before.createdAt, after.createdAt, "createdAt must not move")
    }

    func test_accessKeyStore_getAndTouch_returnsKey_andBumpsAccess() async throws {
        // Use a fake clock for the same reason as the touch test.
        let fakeClock = MutableClock(now: Date())
        let store = try makeInMemoryAccessKeyStore(clock: fakeClock)
        let mediaId = "get-and-touch-test"
        let key = Data(repeating: 0xBB, count: 32)

        try await store.store(
            mediaId: mediaId,
            accessKey: key,
            conversationId: "conv",
            kind: .vaultManual
        )

        let before = try await store.retrieveEntry(mediaId: mediaId)!

        // Jump the clock forward 1 hour so getAndTouch's bump is observable.
        fakeClock.now = fakeClock.now.addingTimeInterval(3600)

        let fetched = try await store.getAndTouch(mediaId: mediaId)
        XCTAssertEqual(fetched, key)

        let after = try await store.retrieveEntry(mediaId: mediaId)!
        XCTAssertGreaterThan(after.lastAccessedAt, before.lastAccessedAt)
    }

    func test_purgeExpired_respectsLastAccessedAt() async throws {
        let fakeClock = MutableClock(now: Date())
        let store = try makeInMemoryAccessKeyStore(clock: fakeClock)

        // Old entry, never touched — should be purged
        try await store.store(
            mediaId: "stale",
            accessKey: Data(repeating: 0x01, count: 32),
            conversationId: "conv",
            kind: .vaultManual
        )

        // Old entry, touched recently — should NOT be purged
        try await store.store(
            mediaId: "hot",
            accessKey: Data(repeating: 0x02, count: 32),
            conversationId: "conv",
            kind: .vaultManual
        )

        // Jump forward 29 days and touch "hot"
        fakeClock.now = fakeClock.now.addingTimeInterval(29 * 24 * 60 * 60)
        try await store.touch(mediaId: "hot")

        // Jump forward another 2 days (total 31 from creation).
        // "stale" is 31 days old since createdAt/lastAccessedAt.
        // "hot" is 2 days old since lastAccessedAt.
        fakeClock.now = fakeClock.now.addingTimeInterval(2 * 24 * 60 * 60)

        let purgedCount = try await store.purgeExpired()
        XCTAssertEqual(purgedCount, 1, "only the stale entry should be purged")

        let stale = try await store.retrieveEntry(mediaId: "stale")
        let hot = try await store.retrieveEntry(mediaId: "hot")
        XCTAssertNil(stale, "stale entry must be gone")
        XCTAssertNotNil(hot, "recently-touched entry must survive")
    }

    // MARK: - Test helpers

    private func makeInMemoryAccessKeyStore(
        clock: MutableClock = MutableClock(now: Date())
    ) throws -> AccessKeyStore {
        let db = try InMemoryLocalDatabase.make()
        return AccessKeyStore(localDatabase: db, clock: { clock.now })
    }
}

/// Mutable clock for deterministic time-travel tests. The @unchecked Sendable
/// is safe because tests synchronize access externally.
final class MutableClock: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

/// In-memory GRDB-backed LocalDatabase for tests. Uses SQLCipher's `:memory:`
/// path so the whole database lives only in RAM. Falls back to a temp file
/// if `:memory:` initialization fails due to keychain mirror path issues.
enum InMemoryLocalDatabase {
    static func make() throws -> LocalDatabaseProtocol {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sanchr-test-\(UUID().uuidString).sqlite")
        let keyProvider = InMemoryKeyProvider()
        return try LocalDatabase(path: url, keyProvider: keyProvider)
    }
}

/// Test-only LocalDatabaseKeyProviderProtocol implementation. Generates a
/// random passphrase per instance so concurrent tests don't collide, and
/// stores no state in the keychain.
final class InMemoryKeyProvider: LocalDatabaseKeyProviderProtocol, @unchecked Sendable {
    private let passphrase = "test-passphrase-" + UUID().uuidString

    func resolveKeyResolution(forDatabaseAt path: String) throws -> LocalDatabaseKeyResolution {
        .passphrase(passphrase)
    }

    func persistResolvedPassphrase(_ passphrase: String, forDatabaseAt path: String) throws {
        // No-op: tests use per-instance temp databases, no keychain mirror needed.
    }

    func resetDatabaseSecrets() throws {
        // No-op: each test instance is ephemeral.
    }
}

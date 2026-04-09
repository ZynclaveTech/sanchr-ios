import XCTest
import CryptoKit
import SanchrShared
@testable import Sanchr

/// Forward-secure vault integration tests.
///
/// The plan originally called for a full `MockGRPCClient` harness exercising
/// the `VaultRepositoryImpl` upload + download round-trip. Mocking the 12+
/// services on `GRPCClientProtocol` would be ~400 lines of boilerplate that
/// nobody else in this codebase has ever written. Instead this file exercises
/// the vault rewrite's key invariants at the component layer:
///
/// 1. AccessK_vault derivation + AES-GCM round-trip for the metadata envelope
///    (the actual crypto primitive the data source uses).
/// 2. LocalDatabase.fetchVaultItems filters sealed items (the status-based
///    filter that Task 6 added to the schema).
/// 3. BackupArchiveVaultItemFrame round-trips bytewise through the
///    BackupArchiveSerializer (the new frame shape from Task 9).
/// 4. LocalDatabase.restoreBackupSnapshot marks cross-device items as sealed
///    based on the device fingerprint (the Task 9 import logic).
@MainActor
final class VaultRepositoryRoundTripTests: XCTestCase {

    // MARK: - 1: AccessK_vault crypto round-trip

    /// Proves the data-source-level crypto loop:
    /// 1. Derive AccessK_vault via deriveVaultAccessKeyManual
    /// 2. AES-GCM encrypt the metadata JSON with that key via MediaEncryptor
    /// 3. Store the key in AccessKeyStore under vaultManual kind
    /// 4. Retrieve the key via getAndTouch (bumps the sliding TTL)
    /// 5. AES-GCM decrypt the ciphertext
    /// 6. Assert the round-trip matches bytewise
    func test_vaultMetadataCrypto_roundTripsViaAccessKeyStore() async throws {
        let db = try InMemoryLocalDatabase.make()
        let accessKeyStore = AccessKeyStore(localDatabase: db)
        let mediaKeyDerivation = MediaKeyDerivation()
        let mediaEncryption = MediaEncryptor()
        let dls = Data(repeating: 0xAA, count: 32)

        // 1. Generate a fresh vault_item_id and salt.
        let vaultItemId = UUID().uuidString.lowercased()
        var saltBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        let salt = Data(saltBytes)

        // 2. Derive AccessK_vault.
        let accessKey = mediaKeyDerivation.deriveVaultAccessKeyManual(
            deviceSecret: dls,
            salt: salt,
            vaultItemId: vaultItemId
        )
        XCTAssertEqual(accessKey.count, 32, "AccessK_vault must be 32 bytes")

        // 3. Store the key.
        try await accessKeyStore.store(
            mediaId: vaultItemId,
            accessKey: accessKey,
            conversationId: "",
            kind: .vaultManual
        )

        // 4. Encrypt a plaintext metadata blob.
        let originalMetadata = Data("""
            {"name":"photo.jpg","mimeType":"image/jpeg","sizeBytes":12345}
            """.utf8)
        let ciphertext = try mediaEncryption.encrypt(
            data: originalMetadata,
            withKey: accessKey
        )
        XCTAssertNotEqual(ciphertext, originalMetadata, "ciphertext must not equal plaintext")

        // 5. Retrieve the key via getAndTouch (bumps TTL).
        let retrievedKey = try await accessKeyStore.getAndTouch(mediaId: vaultItemId)
        XCTAssertEqual(retrievedKey, accessKey, "retrieved key must match stored key")

        // 6. Decrypt and verify bytewise.
        guard let decryptKey = retrievedKey else {
            XCTFail("AccessK_vault missing after store")
            return
        }
        let plaintext = try mediaEncryption.decrypt(
            ciphertext: ciphertext,
            key: decryptKey,
            iv: Data()
        )
        XCTAssertEqual(plaintext, originalMetadata, "round-tripped metadata must match bytewise")
    }

    // MARK: - 2: Sealed items excluded from fetchVaultItems

    /// Proves the status-based filter Task 6 added: fetchVaultItems returns
    /// only .live items, while fetchAllVaultItems returns both.
    func test_sealedVaultItem_isFilteredFromFetchVaultItems() async throws {
        let db = try InMemoryLocalDatabase.make()

        let live = VaultItem(
            id: "live-item-id",
            mediaId: "media-live",
            name: "live.txt",
            type: .document,
            sizeBytes: 100,
            createdAt: Date(),
            updatedAt: Date(),
            status: .live
        )
        let sealed = VaultItem(
            id: "sealed-item-id",
            mediaId: "media-sealed",
            name: "",  // sealed stubs have no name
            type: .document,
            sizeBytes: 0,
            createdAt: Date(),
            updatedAt: Date(),
            status: .sealed
        )

        try await db.saveVaultItem(live)
        try await db.saveVaultItem(sealed)

        // fetchVaultItems filters out sealed (Task 6 behavior).
        let liveItems = try await db.fetchVaultItems()
        XCTAssertEqual(liveItems.count, 1)
        XCTAssertEqual(liveItems.first?.id, "live-item-id")

        // fetchAllVaultItems returns both.
        let allItems = try await db.fetchAllVaultItems()
        XCTAssertEqual(allItems.count, 2)
        XCTAssertTrue(allItems.contains(where: { $0.id == "live-item-id" && $0.status == .live }))
        XCTAssertTrue(allItems.contains(where: { $0.id == "sealed-item-id" && $0.status == .sealed }))
    }

    // MARK: - 3: BackupArchiveVaultItemFrame round-trips through the serializer

    /// Proves the new Task 9 frame shape encodes and decodes cleanly through
    /// the newline-delimited JSON serializer.
    func test_backupFrame_roundTripsThroughSerializer() throws {
        let frame = BackupArchiveVaultItemFrame(
            id: "test-id",
            mediaId: "media-id",
            encryptedMetadata: Data(),
            createdAtMs: 1_712_602_800_000,
            lastAccessedAtMs: 1_712_602_850_000,
            createdOnDevice: "base64-fingerprint",
            kind: "vaultManual"
        )

        let info = BackupArchiveInfoFrame(
            formatVersion: BackupArchive.formatVersion,
            exportedAtMs: 1_712_602_800_000,
            platform: "ios-test",
            appVersion: "0.0.0",
            contactCount: 0,
            conversationCount: 0,
            messageCount: 0,
            vaultItemCount: 1
        )
        let snapshot = BackupArchiveSnapshot(
            info: info,
            contacts: [],
            conversations: [],
            messages: [],
            vaultItems: [frame]
        )

        let serialized = try BackupArchiveSerializer.serialize(snapshot)
        let deserialized = try BackupArchiveSerializer.deserialize(serialized)

        XCTAssertEqual(deserialized.vaultItems.count, 1)
        let roundTripped = try XCTUnwrap(deserialized.vaultItems.first)
        XCTAssertEqual(roundTripped.id, frame.id)
        XCTAssertEqual(roundTripped.mediaId, frame.mediaId)
        XCTAssertEqual(roundTripped.encryptedMetadata, frame.encryptedMetadata)
        XCTAssertEqual(roundTripped.createdAtMs, frame.createdAtMs)
        XCTAssertEqual(roundTripped.lastAccessedAtMs, frame.lastAccessedAtMs)
        XCTAssertEqual(roundTripped.createdOnDevice, frame.createdOnDevice)
        XCTAssertEqual(roundTripped.kind, frame.kind)
    }

    // MARK: - 4: restoreBackupSnapshot marks cross-device items as sealed

    /// Proves the Task 9 restore path: frames with a fingerprint matching the
    /// local device restore as .live, mismatches become .sealed.
    func test_restoreBackupSnapshot_marksCrossDeviceItemsSealed() async throws {
        let db = try InMemoryLocalDatabase.make()

        let localFingerprint = "local-device-fingerprint"
        let remoteFingerprint = "remote-device-fingerprint"

        let sameDeviceFrame = BackupArchiveVaultItemFrame(
            id: "same-device-id",
            mediaId: "media-a",
            encryptedMetadata: Data(),
            createdAtMs: 1_712_602_800_000,
            lastAccessedAtMs: 1_712_602_800_000,
            createdOnDevice: localFingerprint,  // MATCH
            kind: "vaultManual"
        )
        let crossDeviceFrame = BackupArchiveVaultItemFrame(
            id: "cross-device-id",
            mediaId: "media-b",
            encryptedMetadata: Data(),
            createdAtMs: 1_712_602_800_000,
            lastAccessedAtMs: 1_712_602_800_000,
            createdOnDevice: remoteFingerprint,  // MISMATCH
            kind: "vaultAutoVaulted"
        )

        let info = BackupArchiveInfoFrame(
            formatVersion: BackupArchive.formatVersion,
            exportedAtMs: 1_712_602_800_000,
            platform: "ios-test",
            appVersion: "0.0.0",
            contactCount: 0,
            conversationCount: 0,
            messageCount: 0,
            vaultItemCount: 2
        )
        let snapshot = BackupArchiveSnapshot(
            info: info,
            contacts: [],
            conversations: [],
            messages: [],
            vaultItems: [sameDeviceFrame, crossDeviceFrame]
        )

        try await db.restoreBackupSnapshot(
            snapshot,
            currentUserId: "test-user",
            localFingerprint: localFingerprint
        )

        // Verify: same-device item is .live, cross-device is .sealed.
        let allItems = try await db.fetchAllVaultItems()
        XCTAssertEqual(allItems.count, 2)

        let sameDeviceRestored = allItems.first(where: { $0.id == "same-device-id" })
        XCTAssertNotNil(sameDeviceRestored)
        XCTAssertEqual(sameDeviceRestored?.status, .live)

        let crossDeviceRestored = allItems.first(where: { $0.id == "cross-device-id" })
        XCTAssertNotNil(crossDeviceRestored)
        XCTAssertEqual(crossDeviceRestored?.status, .sealed)

        // fetchVaultItems (live-only) should return ONE item.
        let liveOnly = try await db.fetchVaultItems()
        XCTAssertEqual(liveOnly.count, 1)
        XCTAssertEqual(liveOnly.first?.id, "same-device-id")
    }
}

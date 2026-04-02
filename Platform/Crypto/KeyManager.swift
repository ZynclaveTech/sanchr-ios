import Foundation
import LibSignalClient

/// Protocol for cryptographic key lifecycle management using libsignal.
protocol KeyManagerProtocol: AnyObject, Sendable {
    /// Generates a new identity key pair if one does not already exist.
    func generateIdentityIfNeeded() throws -> IdentityKeyPair

    /// Generates a signed pre-key (should be rotated monthly).
    func generateSignedPreKey() throws -> SignedPreKeyRecord

    /// Generates a batch of one-time pre-keys.
    func generateOneTimePreKeys(count: Int) throws -> [PreKeyRecord]

    /// Uploads the full key bundle (identity + signed pre-key + OTPKs) to the server.
    func uploadInitialKeyBundle() async throws

    /// Replenishes one-time pre-keys when the server count is low.
    func replenishPreKeys() async throws

    /// Checks the server pre-key count and replenishes if below threshold.
    func checkAndReplenishPreKeys(threshold: Int) async throws

    /// Fetches a recipient's pre-key bundle from the server for session establishment.
    func fetchPreKeyBundle(userId: String, deviceId: Int32) async throws -> PreKeyBundle

    /// Fetches all device IDs for a given user from the key service.
    func fetchUserDevices(recipientId: String) async throws -> [Int32]

    /// Returns `true` if identity keys have been generated for this device.
    var hasIdentityKeys: Bool { get }
}

/// Manages Signal Protocol key generation, secure storage, and server synchronization.
///
/// This class coordinates between the local `SanchrSignalStore` (Keychain + file persistence)
/// and the remote `KeyService` gRPC endpoint to ensure the device always has valid keys
/// and that the server holds enough one-time pre-keys for incoming session requests.
final class SignalKeyManager: KeyManagerProtocol, @unchecked Sendable {

    // MARK: - Properties

    private let store: SanchrSignalStore
    private let keyService: Vync_Keys_KeyServiceClientProtocol

    /// Default number of one-time pre-keys to generate per batch.
    private static let defaultPreKeyBatchSize = 100

    /// Threshold below which the server should be replenished with more pre-keys.
    private static let defaultReplenishThreshold = 25

    // MARK: - Init

    init(store: SanchrSignalStore, keyService: Vync_Keys_KeyServiceClientProtocol) {
        self.store = store
        self.keyService = keyService
        SanchrLogger.crypto.info("SignalKeyManager initialized")
    }

    // MARK: - KeyManagerProtocol

    var hasIdentityKeys: Bool {
        store.identityStore.hasIdentityKeys
    }

    // MARK: - Initial Setup (called once on registration)

    func generateIdentityIfNeeded() throws -> IdentityKeyPair {
        if hasIdentityKeys {
            SanchrLogger.crypto.info("Identity keys already exist, loading from Keychain")
            return try store.identityStore.identityKeyPair(context: NullContext())
        }
        SanchrLogger.crypto.info("Generating new identity key pair")
        return try store.identityStore.generateAndStoreIdentity()
    }

    func generateSignedPreKey() throws -> SignedPreKeyRecord {
        let identityKeyPair = try store.identityStore.identityKeyPair(context: NullContext())

        // Use a timestamp-based ID for signed pre-keys to ensure uniqueness across rotations.
        let signedPreKeyId = UInt32(Date().timeIntervalSince1970) & 0x00FFFFFF
        let signedPreKeyPair = IdentityKeyPair.generate()

        let signedPreKey = try SignedPreKeyRecord(
            id: signedPreKeyId,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            privateKey: signedPreKeyPair.privateKey,
            signature: identityKeyPair.privateKey.generateSignature(
                message: signedPreKeyPair.publicKey.serialize()
            )
        )

        try store.signedPreKeyStore.storeSignedPreKey(signedPreKey, id: signedPreKeyId, context: NullContext())
        SanchrLogger.crypto.info("Generated signed pre-key with ID \(signedPreKeyId)")
        return signedPreKey
    }

    func generateOneTimePreKeys(count: Int = 100) throws -> [PreKeyRecord] {
        let startId = store.preKeyStore.nextPreKeyId
        var preKeys: [PreKeyRecord] = []
        preKeys.reserveCapacity(count)

        for i in 0..<UInt32(count) {
            let preKeyId = startId + i
            let preKey = try PreKeyRecord(id: preKeyId, privateKey: PrivateKey.generate())
            try store.preKeyStore.storePreKey(preKey, id: preKeyId, context: NullContext())
            preKeys.append(preKey)
        }

        SanchrLogger.crypto.info("Generated \(count) one-time pre-keys (IDs \(startId)...\(startId + UInt32(count) - 1))")
        return preKeys
    }

    // MARK: - Server Sync

    func uploadInitialKeyBundle() async throws {
        let identityKeyPair = try store.identityStore.identityKeyPair(context: NullContext())
        let signedPreKey = try generateSignedPreKey()
        let oneTimePreKeys = try generateOneTimePreKeys(count: Self.defaultPreKeyBatchSize)

        // Build the proto key bundle
        var bundle = Vync_Keys_KeyBundle()
        bundle.identityPublicKey = Data(identityKeyPair.identityKey.serialize())

        var signedPreKeyProto = Vync_Keys_SignedPreKey()
        signedPreKeyProto.keyID = Int32(signedPreKey.id)
        signedPreKeyProto.publicKey = Data(signedPreKey.publicKey.serialize())
        signedPreKeyProto.signature = Data(signedPreKey.signature)
        bundle.signedPreKey = signedPreKeyProto

        bundle.oneTimePreKeys = try oneTimePreKeys.map { preKey in
            var otpk = Vync_Keys_OneTimePreKey()
            otpk.keyID = Int32(preKey.id)
            otpk.publicKey = Data(preKey.publicKey.serialize())
            return otpk
        }

        _ = try await keyService.uploadKeyBundle(bundle)
        SanchrLogger.crypto.info("Uploaded initial key bundle to server")
    }

    func replenishPreKeys() async throws {
        let newPreKeys = try generateOneTimePreKeys(count: Self.defaultPreKeyBatchSize)

        var request = Vync_Keys_UploadOneTimePreKeysRequest()
        request.keys = try newPreKeys.map { preKey in
            var otpk = Vync_Keys_OneTimePreKey()
            otpk.keyID = Int32(preKey.id)
            otpk.publicKey = Data(preKey.publicKey.serialize())
            return otpk
        }

        let response = try await keyService.uploadOneTimePreKeys(request)
        SanchrLogger.crypto.info("Replenished pre-keys, server now has \(response.count)")
    }

    func checkAndReplenishPreKeys(threshold: Int = 25) async throws {
        let request = Vync_Keys_GetPreKeyCountRequest()
        let response = try await keyService.getPreKeyCount(request)

        if response.count < Int32(threshold) {
            SanchrLogger.crypto.info("Server pre-key count (\(response.count)) below threshold (\(threshold)), replenishing")
            try await replenishPreKeys()
        } else {
            SanchrLogger.crypto.info("Server pre-key count (\(response.count)) is sufficient")
        }
    }

    // MARK: - Pre-Key Bundle Fetching

    func fetchPreKeyBundle(userId: String, deviceId: Int32) async throws -> PreKeyBundle {
        var request = Vync_Keys_GetPreKeyBundleRequest()
        request.userID = userId
        request.deviceID = deviceId

        let response = try await keyService.getPreKeyBundle(request)

        // Parse the server response into a libsignal PreKeyBundle
        let identityKey = try IdentityKey(bytes: [UInt8](response.identityPublicKey))

        guard let signedPreKeyProto = response.signedPreKey else {
            throw AppError.encryptionFailed(reason: "Server response missing signed pre-key.")
        }

        let signedPreKeyPublic = try PublicKey(signedPreKeyProto.publicKey)

        // One-time pre-key is optional (may be exhausted on server)
        var preKeyId: UInt32?
        var preKeyPublic: PublicKey?
        if let otpk = response.oneTimePreKey, !otpk.publicKey.isEmpty {
            preKeyId = UInt32(otpk.keyID)
            preKeyPublic = try PublicKey(otpk.publicKey)
        }

        // Registration ID is not returned by our server; use 0 as placeholder.
        // The real registration ID is only needed for multi-device scenarios.
        let registrationId: UInt32 = 0

        let bundle = try PreKeyBundle(
            registrationId: registrationId,
            deviceId: UInt32(deviceId),
            prekeyId: preKeyId,
            prekey: preKeyPublic,
            signedPrekeyId: UInt32(signedPreKeyProto.keyID),
            signedPrekey: signedPreKeyPublic,
            signedPrekeySignature: [UInt8](signedPreKeyProto.signature),
            identity: identityKey
        )

        SanchrLogger.crypto.info("Fetched pre-key bundle for \(userId.prefix(8))... device \(deviceId)")
        return bundle
    }

    // MARK: - Device Management

    func fetchUserDevices(recipientId: String) async throws -> [Int32] {
        var request = Vync_Keys_GetUserDevicesRequest()
        request.userID = recipientId
        let response = try await keyService.getUserDevices(request)

        // If the server returns no devices, default to device 1 (primary).
        if response.deviceIDs.isEmpty {
            return [1]
        }
        return response.deviceIDs
    }
}

// MARK: - NullContext

/// A minimal `StoreContext` implementation for use outside of libsignal's internal callbacks.
/// When calling store methods directly (not from within encrypt/decrypt), we pass this.
struct NullContext: StoreContext {}

import Foundation
import LibSignalClient

/// Protocol for cryptographic key lifecycle management using libsignal.
public protocol KeyManagerProtocol: AnyObject, Sendable {
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

    /// Returns the number of one-time pre-keys currently registered on the server.
    func fetchPreKeyCount() async throws -> Int

    /// Returns the creation timestamp of the current signed pre-key, or nil if none exists.
    func signedPreKeyCreatedAt() throws -> Date?

    /// Regenerates the identity key pair and re-uploads the full key bundle.
    /// ⚠️ Destructive: invalidates all existing sessions and changes the safety number.
    func resetIdentityKeys() async throws

    /// Returns `true` if identity keys have been generated for this device.
    var hasIdentityKeys: Bool { get }
}

/// Manages Signal Protocol key generation, secure storage, and server synchronization.
///
/// This class coordinates between the local `SanchrSignalStore` (Keychain + file persistence)
/// and the remote `KeyService` gRPC endpoint to ensure the device always has valid keys
/// and that the server holds enough one-time pre-keys for incoming session requests.
public final class SignalKeyManager: KeyManagerProtocol, @unchecked Sendable {

    // MARK: - Properties

    private let store: SanchrSignalStore
    private let keyService: Sanchr_Keys_KeyServiceAsyncClientProtocol

    /// Default number of one-time pre-keys to generate per batch.
    private static let defaultPreKeyBatchSize = 100

    /// Threshold below which the server should be replenished with more pre-keys.
    private static let defaultReplenishThreshold = 25

    // MARK: - Init

    public init(store: SanchrSignalStore, keyService: Sanchr_Keys_KeyServiceAsyncClientProtocol) {
        self.store = store
        self.keyService = keyService
        SanchrLogger.crypto.info("SignalKeyManager initialized")
    }

    // MARK: - KeyManagerProtocol

    public var hasIdentityKeys: Bool {
        store.identityStore.hasIdentityKeys
    }

    // MARK: - Initial Setup (called once on registration)

    public func generateIdentityIfNeeded() throws -> IdentityKeyPair {
        if hasIdentityKeys {
            SanchrLogger.crypto.info("Identity keys already exist, loading from Keychain")
            return try store.identityStore.identityKeyPair(context: NullContext())
        }
        SanchrLogger.crypto.info("Generating new identity key pair")
        return try store.identityStore.generateAndStoreIdentity()
    }

    public func generateSignedPreKey() throws -> SignedPreKeyRecord {
        let identityKeyPair = try store.identityStore.identityKeyPair(context: NullContext())

        // Use a timestamp-based ID for signed pre-keys to ensure uniqueness across rotations.
        let signedPreKeyId = UInt32(Date().timeIntervalSince1970) & 0x00FF_FFFF
        let signedPreKeyPair = IdentityKeyPair.generate()

        let signedPreKey = try SignedPreKeyRecord(
            id: signedPreKeyId,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            privateKey: signedPreKeyPair.privateKey,
            signature: identityKeyPair.privateKey.generateSignature(
                message: signedPreKeyPair.publicKey.serialize()
            )
        )

        try store.signedPreKeyStore.storeSignedPreKey(
            signedPreKey, id: signedPreKeyId, context: NullContext())
        SanchrLogger.crypto.info("Generated signed pre-key with ID \(signedPreKeyId)")
        return signedPreKey
    }

    public func generateOneTimePreKeys(count: Int = 100) throws -> [PreKeyRecord] {
        let startId = store.preKeyStore.nextPreKeyId
        var preKeys: [PreKeyRecord] = []
        preKeys.reserveCapacity(count)

        for i in 0..<UInt32(count) {
            let preKeyId = startId + i
            let preKey = try PreKeyRecord(id: preKeyId, privateKey: PrivateKey.generate())
            try store.preKeyStore.storePreKey(preKey, id: preKeyId, context: NullContext())
            preKeys.append(preKey)
        }

        SanchrLogger.crypto.info(
            "Generated \(count) one-time pre-keys (IDs \(startId)...\(startId + UInt32(count) - 1))"
        )
        return preKeys
    }

    // MARK: - Server Sync

    public func uploadInitialKeyBundle() async throws {
        let identityKeyPair = try store.identityStore.identityKeyPair(context: NullContext())
        let registrationId = try store.identityStore.localRegistrationId(context: NullContext())
        let signedPreKey = try generateSignedPreKey()
        let kyberPreKey = try generateKyberPreKey(identityKeyPair: identityKeyPair)
        let oneTimePreKeys = try generateOneTimePreKeys(count: Self.defaultPreKeyBatchSize)

        // Build the proto key bundle
        var bundle = Sanchr_Keys_KeyBundle()
        bundle.identityPublicKey = Data(identityKeyPair.identityKey.serialize())
        bundle.registrationID = Int32(registrationId)

        var signedPreKeyProto = Sanchr_Keys_SignedPreKey()
        signedPreKeyProto.keyID = Int32(signedPreKey.id)
        signedPreKeyProto.publicKey = Data(try signedPreKey.publicKey().serialize())
        signedPreKeyProto.signature = Data(signedPreKey.signature)
        signedPreKeyProto.timestamp = Int64(signedPreKey.timestamp)
        bundle.signedPreKey = signedPreKeyProto

        var kyberPreKeyProto = Sanchr_Keys_KyberPreKey()
        kyberPreKeyProto.keyID = Int32(kyberPreKey.id)
        kyberPreKeyProto.publicKey = Data(try kyberPreKey.publicKey().serialize())
        kyberPreKeyProto.signature = Data(kyberPreKey.signature)
        kyberPreKeyProto.timestamp = Int64(kyberPreKey.timestamp)
        bundle.kyberPreKey = kyberPreKeyProto

        bundle.oneTimePreKeys = try oneTimePreKeys.map { preKey in
            var otpk = Sanchr_Keys_OneTimePreKey()
            otpk.keyID = Int32(preKey.id)
            otpk.publicKey = Data(try preKey.publicKey().serialize())
            return otpk
        }

        _ = try await keyService.uploadKeyBundle(bundle)
        SanchrLogger.crypto.info("Uploaded initial key bundle to server")
    }

    public func replenishPreKeys() async throws {
        let newPreKeys = try generateOneTimePreKeys(count: Self.defaultPreKeyBatchSize)

        var request = Sanchr_Keys_UploadOneTimePreKeysRequest()
        request.keys = try newPreKeys.map { preKey in
            var otpk = Sanchr_Keys_OneTimePreKey()
            otpk.keyID = Int32(preKey.id)
            otpk.publicKey = Data(try preKey.publicKey().serialize())
            return otpk
        }

        let response = try await keyService.uploadOneTimePreKeys(request)
        SanchrLogger.crypto.info("Replenished pre-keys, server now has \(response.count)")
    }

    public func checkAndReplenishPreKeys(threshold: Int = 25) async throws {
        let request = Sanchr_Keys_GetPreKeyCountRequest()
        let response = try await keyService.getPreKeyCount(request)

        if response.count < Int32(threshold) {
            SanchrLogger.crypto.info(
                "Server pre-key count (\(response.count)) below threshold (\(threshold)), replenishing"
            )
            try await replenishPreKeys()
        } else {
            SanchrLogger.crypto.info("Server pre-key count (\(response.count)) is sufficient")
        }
    }

    public func fetchPreKeyCount() async throws -> Int {
        let request = Sanchr_Keys_GetPreKeyCountRequest()
        let response = try await keyService.getPreKeyCount(request)
        return Int(response.count)
    }

    public func signedPreKeyCreatedAt() throws -> Date? {
        let id = store.signedPreKeyStore.currentSignedPreKeyId
        guard id != 0 else { return nil }
        let record = try store.signedPreKeyStore.loadSignedPreKey(id: id, context: NullContext())
        // timestamp is stored as milliseconds since epoch (UInt64)
        return Date(timeIntervalSince1970: Double(record.timestamp) / 1000.0)
    }

    public func resetIdentityKeys() async throws {
        // 1. Regenerate identity key pair unconditionally
        _ = try store.identityStore.generateAndStoreIdentity()

        // 2. Clear all on-device sessions — they are derived from the old identity key
        //    and will fail to decrypt after reset. Contacts must re-establish new sessions.
        let allAddresses = store.sessionStore.allSessionAddresses()
        for address in allAddresses {
            do {
                try store.sessionStore.deleteSession(for: address)
            } catch {
                SanchrLogger.crypto.error(
                    "Failed to delete session for \(address.name).\(address.deviceId) during identity reset: \(error)"
                )
            }
        }

        // Eagerly clear all verified identity flags — safety numbers are now invalid.
        // Lazy clearing via isTrustedIdentity only fires on incoming messages;
        // outgoing sessions would otherwise show stale "verified" badges.
        store.identityStore.clearAllVerifications()

        // FIXME: SanchrSenderKeyStore has no deleteAll API — group sender key chains
        // remain under the old signing identity after reset. Add deleteAllSenderKeys()
        // (clear in-memory dict + remove all .senderkey files from storageDirectory)
        // to SanchrSenderKeyStore and call it here to fully invalidate group sessions.
        // FIXME: store.identityStore.trustedIdentities still holds cached remote keys
        // from before the reset. These become stale if a contact is displayed by identity
        // before they re-send a message (which triggers saveIdentity + key-change event).
        // Clearing trustedIdentities here would wipe all cached remote keys eagerly.

        // 3. Upload new key bundle to server
        try await uploadInitialKeyBundle()
        SanchrLogger.crypto.info("Identity keys reset, \(allAddresses.count) sessions cleared, new bundle uploaded")
    }

    // MARK: - Pre-Key Bundle Fetching

    public func fetchPreKeyBundle(userId: String, deviceId: Int32) async throws -> PreKeyBundle {
        var request = Sanchr_Keys_GetPreKeyBundleRequest()
        request.userID = userId
        request.deviceID = deviceId

        let response = try await keyService.getPreKeyBundle(request)

        // Parse the server response into a libsignal PreKeyBundle
        let identityKey = try IdentityKey(bytes: [UInt8](response.identityPublicKey))

        guard response.hasSignedPreKey else {
            throw AppError.encryptionFailed(reason: "Server response missing signed pre-key.")
        }
        let signedPreKeyProto = response.signedPreKey
        guard response.hasKyberPreKey else {
            throw AppError.encryptionFailed(reason: "Server response missing kyber pre-key.")
        }

        let signedPreKeyPublic = try PublicKey(signedPreKeyProto.publicKey)
        let kyberPreKeyProto = response.kyberPreKey
        let kyberPreKeyPublic = try KEMPublicKey(kyberPreKeyProto.publicKey)
        let registrationId = UInt32(response.registrationID)

        // One-time pre-key is optional (may be exhausted on server)
        let bundle: PreKeyBundle
        if response.hasOneTimePreKey, !response.oneTimePreKey.publicKey.isEmpty {
            let otpk = response.oneTimePreKey
            let preKeyPublic = try PublicKey(otpk.publicKey)
            bundle = try PreKeyBundle(
                registrationId: registrationId,
                deviceId: UInt32(deviceId),
                prekeyId: UInt32(otpk.keyID),
                prekey: preKeyPublic,
                signedPrekeyId: UInt32(signedPreKeyProto.keyID),
                signedPrekey: signedPreKeyPublic,
                signedPrekeySignature: [UInt8](signedPreKeyProto.signature),
                identity: identityKey,
                kyberPrekeyId: UInt32(kyberPreKeyProto.keyID),
                kyberPrekey: kyberPreKeyPublic,
                kyberPrekeySignature: [UInt8](kyberPreKeyProto.signature)
            )
        } else {
            bundle = try PreKeyBundle(
                registrationId: registrationId,
                deviceId: UInt32(deviceId),
                signedPrekeyId: UInt32(signedPreKeyProto.keyID),
                signedPrekey: signedPreKeyPublic,
                signedPrekeySignature: [UInt8](signedPreKeyProto.signature),
                identity: identityKey,
                kyberPrekeyId: UInt32(kyberPreKeyProto.keyID),
                kyberPrekey: kyberPreKeyPublic,
                kyberPrekeySignature: [UInt8](kyberPreKeyProto.signature)
            )
        }

        SanchrLogger.crypto.info(
            "Fetched pre-key bundle for \(userId.prefix(8))... device \(deviceId)")
        return bundle
    }

    // MARK: - Device Management

    public func fetchUserDevices(recipientId: String) async throws -> [Int32] {
        let devices = try await fetchDeviceInfo(recipientId: recipientId)
            .filter(\.keyCapable)
            .map(\.deviceID)

        if devices.isEmpty {
            throw AppError.sessionNotEstablished
        }
        return devices
    }

    public func hasCompleteServerBundle(userId: String, deviceId: Int32) async throws -> Bool {
        try await fetchDeviceInfo(recipientId: userId)
            .contains(where: { $0.deviceID == deviceId && $0.keyCapable })
    }

    /// Devices currently registered for `userId`. Used by Settings to report a real
    /// session count instead of a hardcoded one.
    public func registeredDeviceCount(userId: String) async throws -> Int {
        try await fetchDeviceInfo(recipientId: userId).count
    }

    private func fetchDeviceInfo(recipientId: String) async throws -> [Sanchr_Keys_DeviceInfo] {
        var request = Sanchr_Keys_GetUserDevicesRequest()
        request.userID = recipientId
        let response = try await keyService.getUserDevices(request)
        return response.devices
    }

    private func generateKyberPreKey(identityKeyPair: IdentityKeyPair) throws -> KyberPreKeyRecord {
        let keyPair = KEMKeyPair.generate()
        let keyId = UInt32(Date().timeIntervalSince1970) & 0x00FF_FFFF
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let signature = identityKeyPair.privateKey.generateSignature(message: keyPair.publicKey.serialize())
        let record = try KyberPreKeyRecord(
            id: keyId,
            timestamp: timestamp,
            keyPair: keyPair,
            signature: signature
        )
        try store.kyberPreKeyStore.storeKyberPreKey(record, id: keyId, context: NullContext())
        return record
    }
}

// MARK: - NullContext

/// A minimal `StoreContext` implementation for use outside of libsignal's internal callbacks.
/// When calling store methods directly (not from within encrypt/decrypt), we pass this.
public struct NullContext: StoreContext { public init() {} }

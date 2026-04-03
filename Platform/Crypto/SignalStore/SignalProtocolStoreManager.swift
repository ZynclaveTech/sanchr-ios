import Foundation
import LibSignalClient

/// Unified Signal Protocol store that conforms to `SignalProtocolStore` by delegating
/// to individual sub-stores for each key type.
///
/// This is the single entry point passed into libsignal encryption/decryption functions.
/// It holds references to all five required stores:
/// - `IdentityKeyStore` (Keychain-backed)
/// - `PreKeyStore` (file-backed)
/// - `SignedPreKeyStore` (Keychain-backed)
/// - `SessionStore` (file-backed)
/// - `SenderKeyStore` (file-backed, for group messaging)
final class SanchrSignalStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore,
    SessionStore, SenderKeyStore
{

    let identityStore: SanchrIdentityKeyStore
    let preKeyStore: SanchrPreKeyStore
    let signedPreKeyStore: SanchrSignedPreKeyStore
    let sessionStore: SanchrSessionStore
    let senderKeyStore: SanchrSenderKeyStore

    /// The local user ID this store belongs to.
    let userId: String

    init(userId: String, keychainService: KeychainServiceProtocol) {
        self.userId = userId
        self.identityStore = SanchrIdentityKeyStore(userId: userId, keychain: keychainService)
        self.preKeyStore = SanchrPreKeyStore(userId: userId)
        self.signedPreKeyStore = SanchrSignedPreKeyStore(userId: userId, keychain: keychainService)
        self.sessionStore = SanchrSessionStore(userId: userId)
        self.senderKeyStore = SanchrSenderKeyStore(userId: userId)

        SanchrLogger.crypto.info("SanchrSignalStore initialized for user \(userId.prefix(8))...")
    }

    // MARK: - IdentityKeyStore Forwarding

    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        try identityStore.identityKeyPair(context: context)
    }

    func localRegistrationId(context: StoreContext) throws -> UInt32 {
        try identityStore.localRegistrationId(context: context)
    }

    func saveIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        try identityStore.saveIdentity(identity, for: address, context: context)
    }

    func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        try identityStore.isTrustedIdentity(
            identity, for: address, direction: direction, context: context)
    }

    func identity(
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityKey? {
        try identityStore.identity(for: address, context: context)
    }

    // MARK: - PreKeyStore Forwarding

    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        try preKeyStore.loadPreKey(id: id, context: context)
    }

    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try preKeyStore.storePreKey(record, id: id, context: context)
    }

    func removePreKey(id: UInt32, context: StoreContext) throws {
        try preKeyStore.removePreKey(id: id, context: context)
    }

    // MARK: - SignedPreKeyStore Forwarding

    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        try signedPreKeyStore.loadSignedPreKey(id: id, context: context)
    }

    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try signedPreKeyStore.storeSignedPreKey(record, id: id, context: context)
    }

    // MARK: - KyberPreKeyStore Forwarding (stub – post-quantum keys not yet used)

    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        throw SignalError.invalidKeyIdentifier("Kyber pre-keys are not supported in this build")
    }

    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        throw SignalError.invalidKeyIdentifier("Kyber pre-keys are not supported in this build")
    }

    func markKyberPreKeyUsed(
        id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext
    ) throws {
        // No-op: Kyber pre-keys are not used in this build.
    }

    // MARK: - SessionStore Forwarding

    func loadSession(
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> SessionRecord? {
        try sessionStore.loadSession(for: address, context: context)
    }

    func loadExistingSessions(
        for addresses: [ProtocolAddress],
        context: StoreContext
    ) throws -> [SessionRecord] {
        try sessionStore.loadExistingSessions(for: addresses, context: context)
    }

    func storeSession(
        _ record: SessionRecord,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws {
        try sessionStore.storeSession(record, for: address, context: context)
    }

    // MARK: - SenderKeyStore Forwarding

    func storeSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
        context: StoreContext
    ) throws {
        try senderKeyStore.storeSenderKey(
            from: sender, distributionId: distributionId, record: record, context: context)
    }

    func loadSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        context: StoreContext
    ) throws -> SenderKeyRecord? {
        try senderKeyStore.loadSenderKey(
            from: sender, distributionId: distributionId, context: context)
    }
}

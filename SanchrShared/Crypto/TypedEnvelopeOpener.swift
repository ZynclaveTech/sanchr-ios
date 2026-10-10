import Foundation
import LibSignalClient

/// What `TypedEnvelopeOpener` needs beyond libsignal's own store protocols:
/// two questions those protocols have no place for.
public protocol TypedEnvelopeStores: SessionStore, IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
    KyberPreKeyStore
{
    /// Every address a session is held for.
    func sessionAddresses() -> [ProtocolAddress]
    /// The addresses whose key on record is `identity` and is not awaiting the
    /// user's review. A key adopted on receive after a change sits in the same
    /// place as one that was vouched for; only the pending mark tells them
    /// apart, and such a key must not vouch for itself.
    func establishedAddresses(holding identity: IdentityKey) -> [ProtocolAddress]
}

/// Opens this app's own envelope — a type byte, then a Signal message — when
/// it arrives with no sender outside the ciphertext.
///
/// The envelope names nobody, so the work is in finding the right session
/// without damaging a wrong one. The old way was to try every session in turn.
///
/// For a message inside an established session that is sound: only the right
/// ratchet authenticates it, and a failed attempt changes nothing. It is still
/// what happens here.
///
/// For the first message of a session it is not. A PreKeySignalMessage carries
/// everything needed to start a session, so it succeeds against *any* address
/// it is tried under — and on the receiving side a changed identity key is
/// accepted rather than refused. A first message from someone new was
/// therefore opened under whichever existing contact was tried first: their
/// session replaced by the stranger's, their safety number flagged as changed,
/// and the stranger's message credited to them. With no sessions at all, it
/// could not be opened.
///
/// So a first message is read twice. The first reading is a rehearsal: it
/// runs against a copy of the stores that keeps what it writes in memory and
/// consumes nothing, and its only purpose is to learn who the payload says
/// the message is from. That claim is then checked — the identity key inside
/// the message must be one already established for the user it names, or be
/// the key the server publishes for them now. Without that check the
/// payload's word would be the only thing tying a key to a person, and anyone
/// could introduce themselves as anyone this device had not yet spoken to.
///
/// Only then is the message opened for real, under the sender's own address
/// and with the real stores, exactly as an envelope that had named its sender
/// would be. That second reading is libsignal's ordinary one, and it is what
/// keeps two things true that copying a session into place would not: a
/// replayed first message is recognised against the session it already
/// started, instead of rolling that session back to its beginning; and a
/// contact's earlier ratchets are archived beside the new one rather than
/// thrown away, so messages still in flight on them can be read.
public final class TypedEnvelopeOpener: @unchecked Sendable {
    public enum OpenError: Error, Equatable {
        /// No session on this device authenticates the message.
        case noSessionAuthenticates
        /// A first message that names no sender, and whose key is not that of
        /// exactly one known contact.
        case senderNotDeclared
        /// The sender it names does not hold the key it was sent with.
        case senderNotVouchedFor
        case unknownType
    }

    public typealias PublishedIdentity = @Sendable (_ userId: String, _ deviceId: Int32) async throws -> IdentityKey?

    /// The address the rehearsal runs under. It exists only in memory.
    private static let rehearsalName = "rehearsal"
    private static let vouchAttempts = 3
    private static let publishedTTL: TimeInterval = 300
    private static let publishedLimit = 128

    private let stores: any TypedEnvelopeStores
    private let localUserId: String
    private let publishedIdentity: PublishedIdentity

    private let lock = NSLock()
    private var published: [String: (identity: IdentityKey?, askedAt: Date)] = [:]

    public init(stores: any TypedEnvelopeStores, localUserId: String, publishedIdentity: @escaping PublishedIdentity) {
        self.stores = stores
        self.localUserId = localUserId
        self.publishedIdentity = publishedIdentity
    }

    public func open(_ envelope: Data) async throws -> SealedDecryptResult {
        let body = [UInt8](envelope.dropFirst())
        switch envelope.first {
        case 0x01: return try await openFirstMessage(try PreKeySignalMessage(bytes: body))
        case 0x02: return try openWithinASession(try SignalMessage(bytes: body))
        default: throw OpenError.unknownType
        }
    }

    // MARK: - Inside an established session

    /// Tries each session; only the right one authenticates the message, and a
    /// miss leaves a session as it was.
    private func openWithinASession(_ message: SignalMessage) throws -> SealedDecryptResult {
        // The local user's own sessions last: a copy from another of their
        // devices is rarer than a message from someone else.
        let addresses = stores.sessionAddresses().sorted { first, _ in first.name != localUserId }
        for address in addresses {
            do {
                let plaintext = try signalDecrypt(
                    message: message, from: address, sessionStore: stores, identityStore: stores,
                    context: NullContext())
                return SealedDecryptResult(
                    plaintext: Data(plaintext), senderUserId: address.name, senderDeviceId: Int32(address.deviceId))
            } catch SignalError.duplicatedMessage(let reason) {
                // Only the session it belongs to can recognise a replay.
                throw SignalError.duplicatedMessage(reason)
            } catch {
                continue
            }
        }
        throw OpenError.noSessionAuthenticates
    }

    // MARK: - The first message of a session

    private func openFirstMessage(_ message: PreKeySignalMessage) async throws -> SealedDecryptResult {
        let identity = IdentityKey(publicKey: try message.identityKey)

        // The rehearsal: nothing it does outlives this function.
        let rehearsal = RehearsalStores(reading: stores)
        let claimed = Data(
            try signalDecryptPreKey(
                message: message, from: try ProtocolAddress(name: Self.rehearsalName, deviceId: 1),
                sessionStore: rehearsal, identityStore: rehearsal, preKeyStore: rehearsal,
                signedPreKeyStore: rehearsal, kyberPreKeyStore: rehearsal, context: NullContext()))
        let sender = try await vouchedSender(of: claimed, holding: identity)

        // For real, under the sender's own address. A replay fails here as a
        // duplicate, and a changed key is recorded for the user to review.
        let plaintext = Data(
            try signalDecryptPreKey(
                message: message, from: sender,
                sessionStore: stores, identityStore: stores, preKeyStore: stores,
                signedPreKeyStore: stores, kyberPreKeyStore: stores, context: NullContext()))
        return SealedDecryptResult(
            plaintext: plaintext, senderUserId: sender.name, senderDeviceId: Int32(sender.deviceId))
    }

    /// The address the message is really from, or a refusal.
    private func vouchedSender(of plaintext: Data, holding identity: IdentityKey) async throws -> ProtocolAddress {
        let established = stores.establishedAddresses(holding: identity)

        guard let declared = Self.declaredSender(in: plaintext) else {
            // A payload from a build that predates the field. The key alone
            // identifies the sender when exactly one known contact holds it.
            guard established.count == 1 else { throw OpenError.senderNotDeclared }
            return established[0]
        }
        let address = try ProtocolAddress(name: declared.userId, deviceId: UInt32(max(1, declared.deviceId)))

        if established.contains(where: { $0.name == declared.userId }) { return address }
        // One of this account's own devices, with this account's own key.
        if declared.userId == localUserId,
           (try? stores.identityKeyPair(context: NullContext()).identityKey) == identity {
            return address
        }
        // A stranger, or a contact whose key has changed: ask the server.
        guard try await isPublished(identity, for: declared.userId, deviceId: declared.deviceId) else {
            throw OpenError.senderNotVouchedFor
        }
        return address
    }

    private static func declaredSender(in plaintext: Data) -> (userId: String, deviceId: Int32)? {
        guard let payload = try? JSONDecoder().decode(InnerPayload.self, from: plaintext),
              let userId = payload.senderUserId, !userId.isEmpty,
              let deviceId = payload.senderDeviceId, deviceId > 0
        else { return nil }
        return (userId, deviceId)
    }

    /// Whether the server publishes `identity` for this user's device.
    ///
    /// Asked more than once on a transport failure, because the message cannot
    /// be opened a second time: giving up on a dropped connection would lose
    /// it for good. Remembered briefly per user and device, so a flood of
    /// first messages all claiming to be one person asks once — which matters
    /// most against a server that predates `GetIdentityKey`, where each answer
    /// costs that person a one-time pre-key.
    ///
    /// There is deliberately no ceiling shared across senders. One was tried:
    /// it could be spent with forgeries, and the next genuine newcomer was
    /// then turned away.
    private func isPublished(_ identity: IdentityKey, for userId: String, deviceId: Int32) async throws -> Bool {
        let key = "\(userId).\(deviceId)"
        if let remembered = remembered(key) { return remembered == identity }

        for attempt in 1...Self.vouchAttempts {
            do {
                let answer = try await publishedIdentity(userId, deviceId)
                remember(answer, for: key)
                return answer == identity
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt < Self.vouchAttempts {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 400_000_000)
                }
            }
        }
        return false
    }

    private func remembered(_ key: String) -> IdentityKey?? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = published[key], Date().timeIntervalSince(entry.askedAt) < Self.publishedTTL else {
            return nil
        }
        return .some(entry.identity)
    }

    private func remember(_ identity: IdentityKey?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if published.count >= Self.publishedLimit, published[key] == nil,
           let oldest = published.min(by: { $0.value.askedAt < $1.value.askedAt })?.key {
            published.removeValue(forKey: oldest)
        }
        published[key] = (identity, Date())
    }
}

/// The stores a first message is rehearsed against: the real keys to read,
/// and nowhere real to write.
///
/// Sessions and identities it is asked to save are kept in memory and dropped
/// with it. Pre-keys are read from the real stores and never removed or
/// marked used, so the message can be opened again for real afterwards.
private final class RehearsalStores: SessionStore, IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
    KyberPreKeyStore
{
    private let real: any TypedEnvelopeStores
    private var sessions: [ProtocolAddress: SessionRecord] = [:]
    private var identities: [ProtocolAddress: IdentityKey] = [:]

    init(reading real: any TypedEnvelopeStores) {
        self.real = real
    }

    // Sessions: in memory only.
    func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        sessions[address]
    }

    func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        addresses.compactMap { sessions[$0] }
    }

    func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        sessions[address] = record
    }

    // Identity: this device's own key is real; what it learns of others is not kept.
    func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        try real.identityKeyPair(context: context)
    }

    func localRegistrationId(context: StoreContext) throws -> UInt32 {
        try real.localRegistrationId(context: context)
    }

    func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        identities[address] = identity
        return .newOrUnchanged
    }

    func isTrustedIdentity(
        _ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext
    ) throws -> Bool {
        // Nothing is being trusted: this reading only finds out who to ask about.
        true
    }

    func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        identities[address]
    }

    // Pre-keys: read, never consumed.
    func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        try real.loadPreKey(id: id, context: context)
    }

    func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {}

    func removePreKey(id: UInt32, context: StoreContext) throws {}

    func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        try real.loadSignedPreKey(id: id, context: context)
    }

    func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {}

    func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        try real.loadKyberPreKey(id: id, context: context)
    }

    func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {}

    func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {}
}

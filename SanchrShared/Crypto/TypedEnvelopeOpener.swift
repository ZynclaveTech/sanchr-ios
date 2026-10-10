import Foundation
import LibSignalClient

/// What `TypedEnvelopeOpener` needs beyond libsignal's own store protocols:
/// the few questions and removals those protocols have no place for.
public protocol TypedEnvelopeStores: SessionStore, IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
    KyberPreKeyStore
{
    /// Every address a session is held for.
    func sessionAddresses() -> [ProtocolAddress]
    func removeSession(for address: ProtocolAddress)
    func removeIdentity(for address: ProtocolAddress)
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
/// So a first message is never opened under a real address. It is opened under
/// a throwaway one, and only once the payload has said who it is from, *and
/// that claim has been checked*, is the session moved to where it belongs.
/// The claim is good if the identity key inside the message is one already
/// established for the user it names, or is the key the server publishes for
/// them now. Without that check the payload's word would be the only thing
/// tying a key to a person, and anyone could introduce themselves as anyone
/// this device had not yet spoken to.
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

    private static let scratchPrefix = "sealedscratch-"
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
        // Anything a previous run left behind when it was killed between
        // opening a message and placing it. It is key material.
        for address in stores.sessionAddresses() where address.name.hasPrefix(Self.scratchPrefix) {
            stores.removeSession(for: address)
            stores.removeIdentity(for: address)
        }
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
        let addresses = stores.sessionAddresses()
            .filter { !$0.name.hasPrefix(Self.scratchPrefix) }
            .sorted { first, _ in first.name != localUserId }
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
        let scratch = try ProtocolAddress(name: Self.scratchPrefix + UUID().uuidString, deviceId: 1)
        defer {
            stores.removeSession(for: scratch)
            stores.removeIdentity(for: scratch)
        }
        let identity = IdentityKey(publicKey: try message.identityKey)
        let plaintext = Data(
            try signalDecryptPreKey(
                message: message, from: scratch,
                sessionStore: stores, identityStore: stores, preKeyStore: stores,
                signedPreKeyStore: stores, kyberPreKeyStore: stores, context: NullContext()))

        let sender = try await vouchedSender(of: plaintext, holding: identity)
        try adopt(scratch, as: sender, holding: identity)
        return SealedDecryptResult(
            plaintext: plaintext, senderUserId: sender.name, senderDeviceId: Int32(sender.deviceId))
    }

    /// The address the message is really from, or a refusal.
    private func vouchedSender(of plaintext: Data, holding identity: IdentityKey) async throws -> ProtocolAddress {
        // Not the throwaway address: opening the message has just put this
        // very key on record there, and it must not count as a contact.
        let established = stores.establishedAddresses(holding: identity)
            .filter { !$0.name.hasPrefix(Self.scratchPrefix) }

        guard let declared = Self.declaredSender(in: plaintext) else {
            // A payload from a build that predates the field. The key alone
            // identifies the sender when exactly one known contact holds it.
            guard established.count == 1 else { throw OpenError.senderNotDeclared }
            return established[0]
        }
        guard !declared.userId.hasPrefix(Self.scratchPrefix) else { throw OpenError.senderNotDeclared }
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
    /// it for good. Remembered briefly, because each answer costs the named
    /// user a one-time pre-key and the question is triggered by envelopes from
    /// people not yet identified — unremembered, a flood of first messages all
    /// claiming to be one person would have this device drain that person's
    /// pre-keys on the sender's behalf.
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

    /// Moves the session from the throwaway address to the sender's own, under
    /// the usual trust rules.
    private func adopt(_ scratch: ProtocolAddress, as sender: ProtocolAddress, holding identity: IdentityKey) throws {
        guard let record = try stores.loadSession(for: scratch, context: NullContext()) else {
            throw OpenError.noSessionAuthenticates
        }
        // Records a changed key for the user to review, exactly as an ordinary
        // receive would.
        guard try stores.isTrustedIdentity(identity, for: sender, direction: .receiving, context: NullContext()) else {
            throw OpenError.senderNotVouchedFor
        }
        _ = try stores.saveIdentity(identity, for: sender, context: NullContext())
        try stores.storeSession(record, for: sender, context: NullContext())
    }
}

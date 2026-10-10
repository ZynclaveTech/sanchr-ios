import Foundation
import LibSignalClient

/// Replaces the signed pre-key and the Kyber pre-key on a schedule.
///
/// Both were generated once, at registration, and never again. They are the
/// long-lived half of every session someone starts with this device: a first
/// message is encrypted to them, and when the one-time pre-keys run out, to
/// them alone. A key that never changes means that whoever one day obtains it
/// can read every first message ever sent to it, however old. Rotating bounds
/// that to the life of one key plus the grace period after it.
///
/// It also bounds the record of base keys kept against each Kyber pre-key
/// (`SeenBaseKeys`), which is only dropped when its key is.
///
/// The order of operations is what makes a rotation safe to interrupt:
///
/// 1. The new pair is stored *before* it is uploaded. From the moment the
///    server has it, a peer may fetch it and send a first message to it.
/// 2. The pair is remembered as pending until the upload is known to have
///    succeeded, and a retry sends that same pair. An upload whose reply was
///    lost may have reached the server; discarding the pair and making
///    another would leave the server handing out keys this device threw away.
/// 3. Only after the upload succeeds does the new signed pre-key become
///    current, which is what restarts the clock.
/// 4. Old keys are kept for a grace period, for peers who fetched a bundle
///    before the rotation and have not yet used it.
public final class PreKeyRotation: @unchecked Sendable {
    /// How long a pair is handed out before it is replaced. Android's value.
    public static let interval: TimeInterval = 7 * 24 * 60 * 60
    /// How long a replaced key is still accepted.
    public static let gracePeriod: TimeInterval = 2 * interval

    public typealias Upload = (Sanchr_Keys_KeyBundle) async throws -> Void

    private let signedPreKeys: SanchrSignedPreKeyStore
    private let kyberPreKeys: SanchrKyberPreKeyStore
    private let identity: () throws -> (keyPair: IdentityKeyPair, registrationId: UInt32)
    private let upload: Upload

    private let lock = NSLock()
    private var isRotating = false

    public init(
        signedPreKeys: SanchrSignedPreKeyStore,
        kyberPreKeys: SanchrKyberPreKeyStore,
        identity: @escaping () throws -> (keyPair: IdentityKeyPair, registrationId: UInt32),
        upload: @escaping Upload
    ) {
        self.signedPreKeys = signedPreKeys
        self.kyberPreKeys = kyberPreKeys
        self.identity = identity
        self.upload = upload
    }

    /// Rotates if the current signed pre-key is at least `interval` old.
    ///
    /// - Returns: whether a new pair was published.
    @discardableResult
    public func rotateIfNeeded(now: Date = Date()) async throws -> Bool {
        guard begin() else { return false }
        defer { end() }

        let context = NullContext()
        let currentId = signedPreKeys.currentSignedPreKeyId
        // No key yet means registration has not finished; that upload, not
        // this one, publishes the first pair.
        guard currentId != 0 else { return false }
        let current = try signedPreKeys.loadSignedPreKey(id: currentId, context: context)
        let age = now.timeIntervalSince1970 - TimeInterval(current.timestamp) / 1000
        guard age >= Self.interval else { return false }

        let (identityKeyPair, registrationId) = try identity()
        let pair = try pendingPair(context: context) ?? makePair(signedBy: identityKeyPair, now: now)

        try await upload(try bundle(for: pair, identity: identityKeyPair, registrationId: registrationId))

        signedPreKeys.markCurrent(pair.signed.id)
        signedPreKeys.pendingRotation = nil
        discardKeysOlderThan(now.addingTimeInterval(-Self.gracePeriod), keeping: pair, context: context)
        SanchrLogger.crypto.info("Rotated signed pre-key to \(pair.signed.id) and Kyber pre-key to \(pair.kyber.id)")
        return true
    }

    // MARK: - The pair

    private typealias Pair = (signed: SignedPreKeyRecord, kyber: KyberPreKeyRecord)

    /// The pair an earlier attempt stored, if both halves are still here.
    private func pendingPair(context: StoreContext) throws -> Pair? {
        guard let pending = signedPreKeys.pendingRotation,
              let signed = try? signedPreKeys.loadSignedPreKey(id: pending.signedPreKeyId, context: context),
              let kyber = try? kyberPreKeys.loadKyberPreKey(id: pending.kyberPreKeyId, context: context)
        else { return nil }
        return (signed, kyber)
    }

    private func makePair(signedBy identityKeyPair: IdentityKeyPair, now: Date) throws -> Pair {
        let timestamp = UInt64(now.timeIntervalSince1970 * 1000)
        let signedId = unusedId(startingAt: now, among: signedPreKeys.heldIds())
        let kyberId = unusedId(startingAt: now, among: kyberPreKeys.heldIds())

        let signedKey = PrivateKey.generate()
        let signed = try SignedPreKeyRecord(
            id: signedId,
            timestamp: timestamp,
            privateKey: signedKey,
            signature: identityKeyPair.privateKey.generateSignature(message: signedKey.publicKey.serialize()))
        let kyberKey = KEMKeyPair.generate()
        let kyber = try KyberPreKeyRecord(
            id: kyberId,
            timestamp: timestamp,
            keyPair: kyberKey,
            signature: identityKeyPair.privateKey.generateSignature(message: kyberKey.publicKey.serialize()))

        try signedPreKeys.stage(signed, id: signedId)
        try kyberPreKeys.storeKyberPreKey(kyber, id: kyberId, context: NullContext())
        signedPreKeys.pendingRotation = (signedId, kyberId)
        return (signed, kyber)
    }

    /// The same id scheme the keys have always had — the low bits of the
    /// time — stepped past any id already in use, which the scheme alone
    /// does not rule out.
    private func unusedId(startingAt now: Date, among held: [UInt32]) -> UInt32 {
        var id = UInt32(truncatingIfNeeded: Int(now.timeIntervalSince1970)) & 0x00FF_FFFF
        while id == 0 || held.contains(id) {
            id = (id + 1) & 0x00FF_FFFF
        }
        return id
    }

    private func bundle(
        for pair: Pair,
        identity identityKeyPair: IdentityKeyPair,
        registrationId: UInt32
    ) throws -> Sanchr_Keys_KeyBundle {
        var bundle = Sanchr_Keys_KeyBundle()
        bundle.identityPublicKey = Data(identityKeyPair.identityKey.serialize())
        bundle.registrationID = Int32(registrationId)

        var signed = Sanchr_Keys_SignedPreKey()
        signed.keyID = Int32(pair.signed.id)
        signed.publicKey = Data(try pair.signed.publicKey().serialize())
        signed.signature = Data(pair.signed.signature)
        signed.timestamp = Int64(pair.signed.timestamp)
        bundle.signedPreKey = signed

        var kyber = Sanchr_Keys_KyberPreKey()
        kyber.keyID = Int32(pair.kyber.id)
        kyber.publicKey = Data(try pair.kyber.publicKey().serialize())
        kyber.signature = Data(pair.kyber.signature)
        kyber.timestamp = Int64(pair.kyber.timestamp)
        bundle.kyberPreKey = kyber
        // No one-time pre-keys: the server adds to what it holds, and they
        // are replenished on their own schedule.
        return bundle
    }

    // MARK: - Old keys

    private func discardKeysOlderThan(_ cutoff: Date, keeping pair: Pair, context: StoreContext) {
        let cutoffMillis = UInt64(max(0, cutoff.timeIntervalSince1970 * 1000))
        for id in signedPreKeys.heldIds() where id != pair.signed.id {
            // A key that can no longer be loaded is not being held.
            let timestamp = (try? signedPreKeys.loadSignedPreKey(id: id, context: context))?.timestamp
            if timestamp.map({ $0 < cutoffMillis }) ?? true { signedPreKeys.remove(id: id) }
        }
        for id in kyberPreKeys.heldIds() where id != pair.kyber.id {
            let timestamp = (try? kyberPreKeys.loadKyberPreKey(id: id, context: context))?.timestamp
            if timestamp.map({ $0 < cutoffMillis }) ?? true { kyberPreKeys.remove(id: id) }
        }
    }

    // MARK: - One at a time

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isRotating else { return false }
        isRotating = true
        return true
    }

    private func end() {
        lock.lock()
        isRotating = false
        lock.unlock()
    }
}

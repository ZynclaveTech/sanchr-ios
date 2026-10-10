import Foundation
import LibSignalClient

/// Keychain-backed storage for signed Kyber pre-keys used by PQXDH.
///
/// These records contain private key material, so they stay off disk and are
/// stored similarly to signed EC pre-keys.
public final class SanchrKyberPreKeyStore: KyberPreKeyStore {
    private let userId: String
    private let keychain: KeychainServiceProtocol
    private var cache: [UInt32: KyberPreKeyRecord] = [:]
    private let queue = DispatchQueue(
        label: "io.sanchr.signal.kyber-prekey-store", attributes: .concurrent)

    /// First messages already accepted against a Kyber pre-key; see `SeenBaseKeys`.
    private let seenBaseKeys: SeenBaseKeys

    public init(userId: String, keychain: KeychainServiceProtocol, baseDirectory: URL? = nil) {
        self.userId = userId
        self.keychain = keychain
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.seenBaseKeys = SeenBaseKeys(
            fileURL: base.appendingPathComponent("SignalStore/\(userId)/kyber-base-keys-seen.json"))
    }

    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        var cached: KyberPreKeyRecord?
        queue.sync { cached = cache[id] }
        if let cached {
            return cached
        }

        let key = keychainKey(for: id)
        guard let data = try keychain.read(forKey: key) else {
            throw SignalError.invalidKeyIdentifier("Kyber pre-key \(id) not found")
        }

        let record = try KyberPreKeyRecord(bytes: [UInt8](data))
        queue.sync(flags: .barrier) { cache[id] = record }
        // A key stored before the list of held ids existed is added to it the
        // first time it is used, so it too can be let go when it is old.
        remember(id)
        return record
    }

    public func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try keychain.save(Data(record.serialize()), forKey: keychainKey(for: id))
        queue.sync(flags: .barrier) { cache[id] = record }
        remember(id)
    }

    // MARK: - Rotation

    /// Every id a key is known to be held for.
    public func heldIds() -> [UInt32] {
        loadHeldIds().sorted()
    }

    /// Forgets a key. The base keys recorded against it go with it the next
    /// time that record is written; see `SeenBaseKeys`.
    public func remove(id: UInt32) {
        try? keychain.delete(forKey: keychainKey(for: id))
        queue.sync(flags: .barrier) { cache[id] = nil }
        saveHeldIds(loadHeldIds().filter { $0 != id })
    }

    private func heldIdsKeychainKey() -> String {
        "io.sanchr.signal.kyber_prekey_ids.\(userId)"
    }

    private func loadHeldIds() -> [UInt32] {
        guard let data = try? keychain.read(forKey: heldIdsKeychainKey()),
              let ids = try? JSONDecoder().decode([UInt32].self, from: data)
        else { return [] }
        return ids
    }

    private func saveHeldIds(_ ids: [UInt32]) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? keychain.save(data, forKey: heldIdsKeychainKey())
    }

    private func remember(_ id: UInt32) {
        let ids = loadHeldIds()
        if !ids.contains(id) { saveHeldIds(ids + [id]) }
    }

    public func markKyberPreKeyUsed(
        id: UInt32,
        signedPreKeyId: UInt32,
        baseKey: PublicKey,
        context: StoreContext
    ) throws {
        // The key itself stays until rotation replaces it; what is spent is
        // this one base key. This did nothing at all, so a first message sent
        // without a one-time pre-key could be replayed as new once the
        // session it started was no longer held.
        let fresh = try seenBaseKeys.insert(
            kyberPreKeyId: id, signedPreKeyId: signedPreKeyId, baseKey: Data(baseKey.serialize()),
            isHeld: { self.holdsKyberPreKey(id: $0) })
        guard fresh else {
            throw SignalError.invalidMessage("reused base key")
        }
    }

    /// Whether a Kyber pre-key with this id is still stored. A keychain that
    /// cannot be read just now counts as "yes": the entries that depend on
    /// the answer are only safe to drop when the key is known to be gone.
    private func holdsKyberPreKey(id: UInt32) -> Bool {
        var cached = false
        queue.sync { cached = cache[id] != nil }
        if cached { return true }
        do {
            return try keychain.read(forKey: keychainKey(for: id)) != nil
        } catch {
            return true
        }
    }

    private func keychainKey(for id: UInt32) -> String {
        "io.sanchr.signal.kyber_prekey.\(userId).\(id)"
    }
}

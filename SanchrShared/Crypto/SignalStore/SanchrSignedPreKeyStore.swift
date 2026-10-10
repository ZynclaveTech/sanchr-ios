import Foundation
import LibSignalClient

/// Keychain-backed storage for signed pre-keys.
///
/// Signed pre-keys are longer-lived than one-time pre-keys and are rotated by
/// `PreKeyRotation`. They are stored in the Keychain for added security since
/// they are signed by the identity key.
///
/// More than one is held at a time. The one the server currently hands out is
/// "current"; the ones before it are kept for a while, because a peer who
/// fetched a bundle before a rotation may still send a first message to it.
public final class SanchrSignedPreKeyStore: SignedPreKeyStore {

    // MARK: - Properties

    private let userId: String
    private let keychain: KeychainServiceProtocol

    /// In-memory cache to avoid repeated Keychain reads.
    private var cache: [UInt32: SignedPreKeyRecord] = [:]
    private let queue = DispatchQueue(
        label: "io.sanchr.signal.signed-prekey-store", attributes: .concurrent)

    /// Tracks the current signed pre-key ID for rotation decisions.
    private(set) var currentSignedPreKeyId: UInt32 = 0

    // MARK: - Init

    public init(userId: String, keychain: KeychainServiceProtocol) {
        self.userId = userId
        self.keychain = keychain
        loadCurrentIdFromKeychain()
    }

    // MARK: - SignedPreKeyStore Protocol

    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        // Check in-memory cache first
        var cached: SignedPreKeyRecord?
        queue.sync { cached = cache[id] }
        if let cached { return cached }

        // Fall back to Keychain
        let key = keychainKey(for: id)
        guard let data = try keychain.read(forKey: key) else {
            SanchrLogger.crypto.error("Signed pre-key not found: \(id)")
            throw AppError.decryptionFailed(reason: "Signed pre-key \(id) not found.")
        }
        let record = try SignedPreKeyRecord(bytes: [UInt8](data))
        queue.sync(flags: .barrier) { cache[id] = record }
        // A key stored before the list of held ids existed is added to it the
        // first time it is used, so it too can be let go when it is old.
        remember(id)
        return record
    }

    /// Stores a key and makes it the current one.
    public func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try stage(record, id: id)
        markCurrent(id)
        SanchrLogger.crypto.info("Stored signed pre-key \(id)")
    }

    // MARK: - Rotation

    /// Stores a key without making it current: it can be used to read a
    /// message, but is not yet the one this device believes the server hands out.
    public func stage(_ record: SignedPreKeyRecord, id: UInt32) throws {
        try keychain.save(Data(record.serialize()), forKey: keychainKey(for: id))
        queue.sync(flags: .barrier) { cache[id] = record }
        remember(id)
    }

    public func markCurrent(_ id: UInt32) {
        currentSignedPreKeyId = id
        persistCurrentId(id)
    }

    /// Every id a key is held for, the current one included.
    public func heldIds() -> [UInt32] {
        var ids = Set(loadHeldIds())
        if currentSignedPreKeyId != 0 { ids.insert(currentSignedPreKeyId) }
        return ids.sorted()
    }

    /// Forgets a key. Never the current one.
    public func remove(id: UInt32) {
        guard id != currentSignedPreKeyId else { return }
        try? keychain.delete(forKey: keychainKey(for: id))
        queue.sync(flags: .barrier) { cache[id] = nil }
        saveHeldIds(loadHeldIds().filter { $0 != id })
    }

    /// The pair of keys a rotation has stored and not yet confirmed
    /// published, so a retry sends the same pair instead of making another.
    public var pendingRotation: (signedPreKeyId: UInt32, kyberPreKeyId: UInt32)? {
        get {
            guard let data = try? keychain.read(forKey: pendingRotationKeychainKey()),
                  let ids = try? JSONDecoder().decode([UInt32].self, from: data), ids.count == 2
            else { return nil }
            return (ids[0], ids[1])
        }
        set {
            if let newValue,
               let data = try? JSONEncoder().encode([newValue.signedPreKeyId, newValue.kyberPreKeyId]) {
                try? keychain.save(data, forKey: pendingRotationKeychainKey())
            } else {
                try? keychain.delete(forKey: pendingRotationKeychainKey())
            }
        }
    }

    // MARK: - Helpers

    private func keychainKey(for id: UInt32) -> String {
        "io.sanchr.signal.signed_prekey.\(userId).\(id)"
    }

    private func heldIdsKeychainKey() -> String {
        "io.sanchr.signal.signed_prekey_ids.\(userId)"
    }

    private func pendingRotationKeychainKey() -> String {
        "io.sanchr.signal.prekey_rotation_pending.\(userId)"
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

    private func currentIdKeychainKey() -> String {
        "io.sanchr.signal.signed_prekey_current_id.\(userId)"
    }

    private func persistCurrentId(_ id: UInt32) {
        var idValue = id
        let data = Data(bytes: &idValue, count: MemoryLayout<UInt32>.size)
        try? keychain.save(data, forKey: currentIdKeychainKey())
    }

    private func loadCurrentIdFromKeychain() {
        guard let data = try? keychain.read(forKey: currentIdKeychainKey()),
            data.count >= 4
        else { return }
        currentSignedPreKeyId = data.withUnsafeBytes { $0.load(as: UInt32.self) }
    }
}

import Foundation
import LibSignalClient

/// Keychain-backed storage for signed pre-keys.
///
/// Signed pre-keys are longer-lived than one-time pre-keys and should be rotated monthly.
/// They are stored in the Keychain for added security since they are signed by the identity key.
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
        return record
    }

    public func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        let data = Data(record.serialize())
        let key = keychainKey(for: id)
        try keychain.save(data, forKey: key)

        queue.sync(flags: .barrier) { cache[id] = record }
        currentSignedPreKeyId = id
        persistCurrentId(id)

        SanchrLogger.crypto.info("Stored signed pre-key \(id)")
    }

    // MARK: - Helpers

    private func keychainKey(for id: UInt32) -> String {
        "io.sanchr.signal.signed_prekey.\(userId).\(id)"
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

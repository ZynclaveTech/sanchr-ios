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

    public init(userId: String, keychain: KeychainServiceProtocol) {
        self.userId = userId
        self.keychain = keychain
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
        return record
    }

    public func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try keychain.save(Data(record.serialize()), forKey: keychainKey(for: id))
        queue.sync(flags: .barrier) { cache[id] = record }
    }

    public func markKyberPreKeyUsed(
        id: UInt32,
        signedPreKeyId: UInt32,
        baseKey: PublicKey,
        context: StoreContext
    ) throws {
        // Keep the latest signed Kyber pre-key available until rotation replaces it.
    }

    private func keychainKey(for id: UInt32) -> String {
        "io.sanchr.signal.kyber_prekey.\(userId).\(id)"
    }
}

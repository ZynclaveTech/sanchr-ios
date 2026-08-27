import Foundation
import Security

/// Protocol for Keychain CRUD operations.
public protocol KeychainServiceProtocol: AnyObject, Sendable {
    func save(_ data: Data, forKey key: String) throws
    func read(forKey key: String) throws -> Data?
    func update(_ data: Data, forKey key: String) throws
    func delete(forKey key: String) throws
    func deleteAll() throws

    /// iCloud-Keychain-synchronized variants. Items written with these sync to
    /// the user's other devices and — crucially — survive an app reinstall, so a
    /// value stored here (the Profile Key) can be recovered rather than
    /// regenerated. They live in a separate synchronizable namespace, so a synced
    /// item and a device-only item with the same key are distinct.
    func saveSynchronized(_ data: Data, forKey key: String) throws
    func readSynchronized(forKey key: String) throws -> Data?
    func deleteSynchronized(forKey key: String) throws
}

extension KeychainServiceProtocol {
    // Default fallbacks so conformers that don't distinguish the two namespaces
    // (e.g. test doubles) keep working — they simply store everything locally.
    public func saveSynchronized(_ data: Data, forKey key: String) throws {
        try save(data, forKey: key)
    }
    public func readSynchronized(forKey key: String) throws -> Data? {
        try read(forKey: key)
    }
    public func deleteSynchronized(forKey key: String) throws {
        try delete(forKey: key)
    }
}

/// Keychain wrapper providing type-safe access to the iOS Keychain.
public final class KeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private let serviceName: String
    private let accessGroup: String?

    public init(serviceName: String = "io.sanchr.keychain", accessGroup: String? = nil) {
        self.serviceName = serviceName
        self.accessGroup = accessGroup
    }

    // MARK: - Device-only (default)

    public func save(_ data: Data, forKey key: String) throws {
        try save(data, forKey: key, synchronizable: false)
    }

    public func read(forKey key: String) throws -> Data? {
        try read(forKey: key, synchronizable: false)
    }

    public func update(_ data: Data, forKey key: String) throws {
        try update(data, forKey: key, synchronizable: false)
    }

    public func delete(forKey key: String) throws {
        try delete(forKey: key, synchronizable: false)
    }

    // MARK: - iCloud-synchronized

    public func saveSynchronized(_ data: Data, forKey key: String) throws {
        try save(data, forKey: key, synchronizable: true)
    }

    public func readSynchronized(forKey key: String) throws -> Data? {
        try read(forKey: key, synchronizable: true)
    }

    public func deleteSynchronized(forKey key: String) throws {
        try delete(forKey: key, synchronizable: true)
    }

    // MARK: - Core operations

    private func save(_ data: Data, forKey key: String, synchronizable: Bool) throws {
        // Delete existing item first to avoid duplicates
        try? delete(forKey: key, synchronizable: synchronizable)

        var query = baseQuery(forKey: key, synchronizable: synchronizable)
        query[kSecValueData as String] = data
        // A synchronizable item cannot be `...ThisDeviceOnly` — that is the whole
        // point (it must be allowed to leave the device), so it uses the plain
        // AfterFirstUnlock class. Device-only items keep the stricter class.
        query[kSecAttrAccessible as String] =
            synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        // The delete above and this add are not atomic, so a concurrent writer
        // (many presence envelopes each store the sender's Profile Key) can leave
        // the item present when SecItemAdd runs — errSecDuplicateItem (-25299).
        // Update in place rather than failing; the value is what matters.
        if status == errSecDuplicateItem {
            try update(data, forKey: key, synchronizable: synchronizable)
            return
        }
        guard status == errSecSuccess else {
            SanchrLogger.crypto.error("Keychain save failed: \(status)")
            throw AppError.keychainWriteFailed
        }
    }

    private func read(forKey key: String, synchronizable: Bool) throws -> Data? {
        var query = baseQuery(forKey: key, synchronizable: synchronizable)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            SanchrLogger.crypto.error("Keychain read failed: \(status)")
            throw AppError.keychainReadFailed
        }
    }

    private func update(_ data: Data, forKey key: String, synchronizable: Bool) throws {
        let query = baseQuery(forKey: key, synchronizable: synchronizable)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            SanchrLogger.crypto.error("Keychain update failed: \(status)")
            throw AppError.keychainWriteFailed
        }
    }

    private func delete(forKey key: String, synchronizable: Bool) throws {
        let query = baseQuery(forKey: key, synchronizable: synchronizable)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            SanchrLogger.crypto.error("Keychain delete failed: \(status)")
            throw AppError.keychainWriteFailed
        }
    }

    public func deleteAll() throws {
        // Clear both namespaces so a full wipe leaves nothing behind.
        for synchronizable in [false, true] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
            ]
            if let group = accessGroup {
                query[kSecAttrAccessGroup as String] = group
            }
            if synchronizable {
                query[kSecAttrSynchronizable as String] = kCFBooleanTrue
            }

            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppError.keychainWriteFailed
            }
        }
    }

    // MARK: - Helpers

    private func baseQuery(forKey key: String, synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        return query
    }
}

import Foundation
import Security

/// Protocol for Keychain CRUD operations.
public protocol KeychainServiceProtocol: AnyObject, Sendable {
    func save(_ data: Data, forKey key: String) throws
    func read(forKey key: String) throws -> Data?
    func update(_ data: Data, forKey key: String) throws
    func delete(forKey key: String) throws
    func deleteAll() throws
}

/// Keychain wrapper providing type-safe access to the iOS Keychain.
public final class KeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private let serviceName: String
    private let accessGroup: String?

    public init(serviceName: String = "io.sanchr.keychain", accessGroup: String? = nil) {
        self.serviceName = serviceName
        self.accessGroup = accessGroup
    }

    public func save(_ data: Data, forKey key: String) throws {
        // Delete existing item first to avoid duplicates
        try? delete(forKey: key)

        var query = baseQuery(forKey: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        // The delete above and this add are not atomic, so a concurrent writer
        // (many presence envelopes each store the sender's Profile Key) can leave
        // the item present when SecItemAdd runs — errSecDuplicateItem (-25299).
        // Update in place rather than failing; the value is what matters.
        if status == errSecDuplicateItem {
            try update(data, forKey: key)
            return
        }
        guard status == errSecSuccess else {
            SanchrLogger.crypto.error("Keychain save failed: \(status)")
            throw AppError.keychainWriteFailed
        }
    }

    public func read(forKey key: String) throws -> Data? {
        var query = baseQuery(forKey: key)
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

    public func update(_ data: Data, forKey key: String) throws {
        let query = baseQuery(forKey: key)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            SanchrLogger.crypto.error("Keychain update failed: \(status)")
            throw AppError.keychainWriteFailed
        }
    }

    public func delete(forKey key: String) throws {
        let query = baseQuery(forKey: key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            SanchrLogger.crypto.error("Keychain delete failed: \(status)")
            throw AppError.keychainWriteFailed
        }
    }

    public func deleteAll() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.keychainWriteFailed
        }
    }

    // MARK: - Helpers

    private func baseQuery(forKey key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }
}

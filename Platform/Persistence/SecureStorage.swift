import Foundation

/// Protocol for encrypted key-value storage backed by Keychain.
protocol SecureStorageProtocol: AnyObject, Sendable {
    func saveAccessToken(_ token: String) throws
    func readAccessToken() throws -> String?
    func saveRefreshToken(_ token: String) throws
    func readRefreshToken() throws -> String?
    func saveIdentityKey(_ key: Data) throws
    func readIdentityKey() throws -> Data?
    func savePreKeys(_ keys: [Data]) throws
    func readPreKeys() throws -> [Data]
    func saveDeviceId(_ deviceId: String) throws
    func readDeviceId() throws -> String?
    func deleteAllTokens() throws
    func deleteAllKeys() throws
}

/// Keychain-backed secure storage for tokens and encryption keys.
final class SecureStorage: SecureStorageProtocol, @unchecked Sendable {
    private let keychain: KeychainServiceProtocol

    private enum Keys {
        static let accessToken = "io.sanchr.access_token"
        static let refreshToken = "io.sanchr.refresh_token"
        static let deviceId = "io.sanchr.device_id"
        static let identityKey = "io.sanchr.identity_key"
        static let preKeys = "io.sanchr.pre_keys"
    }

    init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
    }

    func saveAccessToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { return }
        try keychain.save(data, forKey: Keys.accessToken)
    }

    func readAccessToken() throws -> String? {
        guard let data = try keychain.read(forKey: Keys.accessToken) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveRefreshToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { return }
        try keychain.save(data, forKey: Keys.refreshToken)
    }

    func readRefreshToken() throws -> String? {
        guard let data = try keychain.read(forKey: Keys.refreshToken) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveIdentityKey(_ key: Data) throws {
        try keychain.save(key, forKey: Keys.identityKey)
    }

    func readIdentityKey() throws -> Data? {
        try keychain.read(forKey: Keys.identityKey)
    }

    func savePreKeys(_ keys: [Data]) throws {
        let archived = try JSONEncoder().encode(keys)
        try keychain.save(archived, forKey: Keys.preKeys)
    }

    func readPreKeys() throws -> [Data] {
        guard let data = try keychain.read(forKey: Keys.preKeys) else { return [] }
        return try JSONDecoder().decode([Data].self, from: data)
    }

    func saveDeviceId(_ deviceId: String) throws {
        guard let data = deviceId.data(using: .utf8) else { return }
        try keychain.save(data, forKey: Keys.deviceId)
    }

    func readDeviceId() throws -> String? {
        guard let data = try keychain.read(forKey: Keys.deviceId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteAllTokens() throws {
        try keychain.delete(forKey: Keys.accessToken)
        try keychain.delete(forKey: Keys.refreshToken)
    }

    func deleteAllKeys() throws {
        try keychain.delete(forKey: Keys.identityKey)
        try keychain.delete(forKey: Keys.preKeys)
    }
}

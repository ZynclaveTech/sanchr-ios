import Foundation
import Security

/// Protocol for encrypted key-value storage backed by Keychain.
public protocol SecureStorageProtocol: AnyObject, Sendable {
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
    func saveInstallationId(_ installationId: String) throws
    func readInstallationId() throws -> String?
    func readOrCreateInstallationId() throws -> String
    func saveSessionSnapshot(_ snapshot: SessionSnapshot) throws
    func readSessionSnapshot() throws -> SessionSnapshot?
    func saveDeviceMasterSecret(_ secret: Data) throws
    func readDeviceMasterSecret() throws -> Data?
    func saveDatabaseKey(_ key: String) throws
    func readDatabaseKey() throws -> String?
    func readOrCreateDatabaseKey() throws -> String
    func saveRecoveryKey(_ key: String) throws
    func readRecoveryKey() throws -> String?
    func saveBackupConfiguration(_ configuration: BackupConfiguration) throws
    func readBackupConfiguration() throws -> BackupConfiguration?
    func deleteBackupConfiguration() throws
    func deleteAllTokens() throws
    func deleteSessionData() throws
    func deleteAllKeys() throws
    func deleteDeviceSecrets() throws
    func deleteBackupMaterial() throws
}

/// Keychain-backed secure storage for tokens and encryption keys.
public final class SecureStorage: SecureStorageProtocol, @unchecked Sendable {
    private let keychain: KeychainServiceProtocol

    private enum Keys {
        static let accessToken = "io.sanchr.access_token"
        static let refreshToken = "io.sanchr.refresh_token"
        static let deviceId = "io.sanchr.device_id"
        static let installationId = "io.sanchr.installation_id"
        static let sessionSnapshot = "io.sanchr.session_snapshot"
        static let deviceMasterSecret = "io.sanchr.device_master_secret"
        static let databaseKey = "io.sanchr.database_key"
        static let recoveryKey = "io.sanchr.recovery_key"
        static let backupConfiguration = "io.sanchr.backup_configuration"
        static let identityKey = "io.sanchr.identity_key"
        static let preKeys = "io.sanchr.pre_keys"
    }

    public init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
    }

    public func saveAccessToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { return }
        try keychain.save(data, forKey: Keys.accessToken)
    }

    public func readAccessToken() throws -> String? {
        guard let data = try keychain.read(forKey: Keys.accessToken) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveRefreshToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { return }
        try keychain.save(data, forKey: Keys.refreshToken)
    }

    public func readRefreshToken() throws -> String? {
        guard let data = try keychain.read(forKey: Keys.refreshToken) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveIdentityKey(_ key: Data) throws {
        try keychain.save(key, forKey: Keys.identityKey)
    }

    public func readIdentityKey() throws -> Data? {
        try keychain.read(forKey: Keys.identityKey)
    }

    public func savePreKeys(_ keys: [Data]) throws {
        let archived = try JSONEncoder().encode(keys)
        try keychain.save(archived, forKey: Keys.preKeys)
    }

    public func readPreKeys() throws -> [Data] {
        guard let data = try keychain.read(forKey: Keys.preKeys) else { return [] }
        return try JSONDecoder().decode([Data].self, from: data)
    }

    public func saveDeviceId(_ deviceId: String) throws {
        guard let data = deviceId.data(using: .utf8) else { return }
        try keychain.save(data, forKey: Keys.deviceId)
    }

    public func readDeviceId() throws -> String? {
        guard let data = try keychain.read(forKey: Keys.deviceId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveInstallationId(_ installationId: String) throws {
        guard let data = installationId.data(using: .utf8) else { return }
        try keychain.save(data, forKey: Keys.installationId)
    }

    public func readInstallationId() throws -> String? {
        guard let data = try keychain.read(forKey: Keys.installationId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func readOrCreateInstallationId() throws -> String {
        if let existing = try readInstallationId(), !existing.isEmpty {
            return existing
        }

        let installationId = UUID().uuidString.lowercased()
        try saveInstallationId(installationId)
        return installationId
    }

    public func saveSessionSnapshot(_ snapshot: SessionSnapshot) throws {
        let archived = try JSONEncoder().encode(snapshot)
        try keychain.save(archived, forKey: Keys.sessionSnapshot)
    }

    public func readSessionSnapshot() throws -> SessionSnapshot? {
        guard let data = try keychain.read(forKey: Keys.sessionSnapshot) else { return nil }
        return try JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    public func saveDeviceMasterSecret(_ secret: Data) throws {
        try keychain.save(secret, forKey: Keys.deviceMasterSecret)
        SanchrLogger.crypto.info("Saved device master secret to Keychain (\(secret.count) bytes)")
    }

    public func readDeviceMasterSecret() throws -> Data? {
        try keychain.read(forKey: Keys.deviceMasterSecret)
    }

    public func saveDatabaseKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else { return }
        try keychain.save(data, forKey: Keys.databaseKey)
        SanchrLogger.crypto.info("Saved fallback database key to Keychain (\(data.count) bytes)")
    }

    public func readDatabaseKey() throws -> String? {
        guard let data = try keychain.read(forKey: Keys.databaseKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func readOrCreateDatabaseKey() throws -> String {
        if let existing = try readDatabaseKey(), !existing.isEmpty {
            return existing
        }

        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            throw AppError.keychainWriteFailed
        }

        let key = Data(randomBytes).base64EncodedString()
        try saveDatabaseKey(key)
        return key
    }

    public func saveRecoveryKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else { return }
        try keychain.save(data, forKey: Keys.recoveryKey)
    }

    public func readRecoveryKey() throws -> String? {
        guard let data = try keychain.read(forKey: Keys.recoveryKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveBackupConfiguration(_ configuration: BackupConfiguration) throws {
        let encoded = try JSONEncoder().encode(configuration)
        try keychain.save(encoded, forKey: Keys.backupConfiguration)
    }

    public func readBackupConfiguration() throws -> BackupConfiguration? {
        guard let data = try keychain.read(forKey: Keys.backupConfiguration) else { return nil }
        return try JSONDecoder().decode(BackupConfiguration.self, from: data)
    }

    public func deleteBackupConfiguration() throws {
        try keychain.delete(forKey: Keys.backupConfiguration)
    }

    public func deleteAllTokens() throws {
        try keychain.delete(forKey: Keys.accessToken)
        try keychain.delete(forKey: Keys.refreshToken)
    }

    public func deleteSessionData() throws {
        try deleteAllTokens()
        try keychain.delete(forKey: Keys.deviceId)
        try keychain.delete(forKey: Keys.installationId)
        try keychain.delete(forKey: Keys.sessionSnapshot)
    }

    public func deleteAllKeys() throws {
        try keychain.delete(forKey: Keys.identityKey)
        try keychain.delete(forKey: Keys.preKeys)
    }

    public func deleteDeviceSecrets() throws {
        SanchrLogger.crypto.warning("Deleting device-bound database secrets from Keychain")
        try keychain.delete(forKey: Keys.deviceMasterSecret)
        try keychain.delete(forKey: Keys.databaseKey)
    }

    public func deleteBackupMaterial() throws {
        try keychain.delete(forKey: Keys.recoveryKey)
        try deleteBackupConfiguration()
    }
}

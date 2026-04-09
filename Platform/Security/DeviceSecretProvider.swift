import CryptoKit
import Foundation
import SanchrShared

protocol DeviceSecretProviderProtocol: AnyObject, Sendable {
    func readDeviceMasterSecret() throws -> Data?
    func readOrCreateDeviceMasterSecret() throws -> Data
    func localDatabasePassphrase() throws -> String
    func localHMACKey() throws -> Data
    func mediaWrapKey() throws -> Data
    func mediaAccessSecret() throws -> Data

    /// One-way fingerprint of the device secret, safe to embed in exported
    /// backup archives. Used by the vault restore path to detect cross-device
    /// restores and mark imported items as sealed.
    ///
    /// `fingerprint = base64(SHA256(dls || "sanchr-backup-fingerprint-v1"))`
    ///
    /// Properties:
    /// - Deterministic on a single device
    /// - Non-invertible (SHA-256 one-way)
    /// - Cannot be used to forge decryption capability — AccessK_vault
    ///   derivation uses the raw dls, not the fingerprint
    /// - Two devices with different dls produce different fingerprints
    func backupFingerprint() throws -> String
    func clearDeviceSecrets() throws
}

final class DeviceSecretProvider: DeviceSecretProviderProtocol, @unchecked Sendable {
    private enum Labels {
        static let sqlCipher = "sanchr.device.sqlcipher.v1"
        static let localHMAC = "sanchr.device.local-hmac.v1"
        static let mediaWrap = "sanchr.device.media-wrap.v1"
        static let mediaAccess = "sanchr.device.media-access.v1"
        static let salt = "sanchr.device.hkdf.v1"
    }

    private let secureStorage: SecureStorageProtocol

    init(secureStorage: SecureStorageProtocol) {
        self.secureStorage = secureStorage
    }

    func readDeviceMasterSecret() throws -> Data? {
        try secureStorage.readDeviceMasterSecret()
    }

    func readOrCreateDeviceMasterSecret() throws -> Data {
        if let existing = try readDeviceMasterSecret(), existing.count == 32 {
            SanchrLogger.crypto.info("Reusing existing device master secret from Keychain")
            return existing
        }

        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            throw AppError.keychainWriteFailed
        }

        let secret = Data(randomBytes)
        try secureStorage.saveDeviceMasterSecret(secret)
        SanchrLogger.crypto.info("Generated new device master secret")
        return secret
    }

    func localDatabasePassphrase() throws -> String {
        try deriveKey(label: Labels.sqlCipher).base64EncodedString()
    }

    func localHMACKey() throws -> Data {
        try deriveKey(label: Labels.localHMAC)
    }

    func mediaWrapKey() throws -> Data {
        try deriveKey(label: Labels.mediaWrap)
    }

    func mediaAccessSecret() throws -> Data {
        try deriveKey(label: Labels.mediaAccess)
    }

    func backupFingerprint() throws -> String {
        let dls = try readOrCreateDeviceMasterSecret()
        let label = "sanchr-backup-fingerprint-v1".data(using: .utf8)!
        var input = Data()
        input.append(dls)
        input.append(label)
        let digest = SHA256.hash(data: input)
        return Data(digest).base64EncodedString()
    }

    func clearDeviceSecrets() throws {
        try secureStorage.deleteDeviceSecrets()
    }

    private func deriveKey(label: String) throws -> Data {
        let secret = SymmetricKey(data: try readOrCreateDeviceMasterSecret())
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secret,
            salt: Data(Labels.salt.utf8),
            info: Data(label.utf8),
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}

import Foundation
import LibSignalClient
import SanchrShared

protocol RecoveryKeyManagerProtocol: AnyObject, Sendable {
    func loadConfiguration() throws -> BackupConfiguration?
    func readRecoveryKey() throws -> String?
    func generateRecoveryKey() throws -> String
    func enableBackups(with recoveryKey: String, lineageId: String) throws -> BackupConfiguration
    func disableBackups() throws
    func updateBackupState(lastBackupAt: Date?, lastBackupContentHash: String?) throws
    func persistRestoredBackup(
        recoveryKey: String,
        lineageId: String,
        formatVersion: Int32,
        lastBackupAt: Date?,
        lastBackupContentHash: String?
    ) throws -> BackupConfiguration
    func clearBackupMaterial() throws
}

final class RecoveryKeyManager: RecoveryKeyManagerProtocol, @unchecked Sendable {
    private let secureStorage: SecureStorageProtocol

    init(secureStorage: SecureStorageProtocol) {
        self.secureStorage = secureStorage
    }

    func loadConfiguration() throws -> BackupConfiguration? {
        try secureStorage.readBackupConfiguration()
    }

    func readRecoveryKey() throws -> String? {
        try secureStorage.readRecoveryKey()
    }

    func generateRecoveryKey() throws -> String {
        let recoveryKey = AccountEntropyPool.generate()
        guard AccountEntropyPool.isValid(recoveryKey) else {
            throw AppError.keyGenerationFailed
        }
        return recoveryKey
    }

    func enableBackups(with recoveryKey: String, lineageId: String) throws -> BackupConfiguration {
        guard AccountEntropyPool.isValid(recoveryKey) else {
            throw AppError.encryptionFailed(reason: "Generated recovery key is invalid")
        }

        let configuration = BackupConfiguration(
            isEnabled: true,
            lineageId: lineageId,
            formatVersion: 1,
            recoveryKeyConfirmedAt: Date(),
            lastBackupAt: nil,
            lastBackupContentHash: nil
        )
        try secureStorage.saveRecoveryKey(recoveryKey)
        try secureStorage.saveBackupConfiguration(configuration)
        return configuration
    }

    func disableBackups() throws {
        try secureStorage.deleteBackupMaterial()
    }

    func updateBackupState(lastBackupAt: Date?, lastBackupContentHash: String?) throws {
        guard let current = try loadConfiguration() else { return }
        let updated = BackupConfiguration(
            isEnabled: current.isEnabled,
            lineageId: current.lineageId,
            formatVersion: current.formatVersion,
            recoveryKeyConfirmedAt: current.recoveryKeyConfirmedAt,
            lastBackupAt: lastBackupAt,
            lastBackupContentHash: lastBackupContentHash
        )
        try secureStorage.saveBackupConfiguration(updated)
    }

    func persistRestoredBackup(
        recoveryKey: String,
        lineageId: String,
        formatVersion: Int32,
        lastBackupAt: Date?,
        lastBackupContentHash: String?
    ) throws -> BackupConfiguration {
        guard AccountEntropyPool.isValid(recoveryKey) else {
            throw AppError.encryptionFailed(reason: "Recovery key is invalid")
        }

        let configuration = BackupConfiguration(
            isEnabled: true,
            lineageId: lineageId,
            formatVersion: formatVersion,
            recoveryKeyConfirmedAt: Date(),
            lastBackupAt: lastBackupAt,
            lastBackupContentHash: lastBackupContentHash
        )
        try secureStorage.saveRecoveryKey(recoveryKey)
        try secureStorage.saveBackupConfiguration(configuration)
        return configuration
    }

    func clearBackupMaterial() throws {
        try secureStorage.deleteBackupMaterial()
    }
}

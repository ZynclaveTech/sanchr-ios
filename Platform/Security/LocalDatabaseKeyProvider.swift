import Foundation
import SanchrShared

final class LocalDatabaseKeyProvider: LocalDatabaseKeyProviderProtocol, @unchecked Sendable {
    private let secureStorage: SecureStorageProtocol
    private let deviceSecrets: DeviceSecretProviderProtocol

    init(
        secureStorage: SecureStorageProtocol,
        deviceSecrets: DeviceSecretProviderProtocol
    ) {
        self.secureStorage = secureStorage
        self.deviceSecrets = deviceSecrets
    }

    func resolveKeyResolution(forDatabaseAt path: String) throws -> LocalDatabaseKeyResolution {
        let databaseExists = FileManager.default.fileExists(atPath: path)
        let deviceMasterSecret = try secureStorage.readDeviceMasterSecret()
        let legacyDatabaseKey = try secureStorage.readDatabaseKey()

        SanchrLogger.persistence.info(
            "Resolving database key: dbExists=\(databaseExists) deviceMasterSecretPresent=\(deviceMasterSecret != nil) fallbackDatabaseKeyPresent=\(legacyDatabaseKey?.isEmpty == false)"
        )

        if let deviceMasterSecret,
           deviceMasterSecret.count == 32 {
            SanchrLogger.persistence.info("Using device master secret derived SQLCipher passphrase")
            return .passphrase(try deviceSecrets.localDatabasePassphrase())
        }

        if let legacyDatabaseKey,
           !legacyDatabaseKey.isEmpty {
            SanchrLogger.persistence.warning("Using fallback database key because device master secret is unavailable")
            return .passphrase(legacyDatabaseKey)
        }

        #if targetEnvironment(simulator)
        if let mirroredPassphrase = try readSimulatorMirror(forDatabaseAt: path),
           !mirroredPassphrase.isEmpty {
            SanchrLogger.persistence.warning("Using simulator-only mirrored database key because Keychain secrets are unavailable")
            return .passphrase(mirroredPassphrase)
        }
        #endif

        if databaseExists {
            SanchrLogger.persistence.error("Database file exists but neither device master secret nor fallback database key was found")
            return .missingSecretForExistingDatabase
        }

        _ = try deviceSecrets.readOrCreateDeviceMasterSecret()
        SanchrLogger.persistence.info("Created fresh device master secret for new database bootstrap")
        return .passphrase(try deviceSecrets.localDatabasePassphrase())
    }

    func persistResolvedPassphrase(_ passphrase: String, forDatabaseAt path: String) throws {
        guard !passphrase.isEmpty else { return }

        if let existing = try secureStorage.readDatabaseKey(),
           existing == passphrase
        {
            SanchrLogger.persistence.info("Fallback database key already matches active SQLCipher passphrase")
        } else {
            try secureStorage.saveDatabaseKey(passphrase)
            SanchrLogger.persistence.info("Persisted fallback database key for SQLCipher recovery")
        }

        #if targetEnvironment(simulator)
        try writeSimulatorMirror(passphrase, forDatabaseAt: path)
        #endif
    }

    func resetDatabaseSecrets() throws {
        SanchrLogger.persistence.warning("Resetting local database secrets")
        try deviceSecrets.clearDeviceSecrets()
    }

    #if targetEnvironment(simulator)
    private func simulatorMirrorPath(forDatabaseAt path: String) -> String {
        URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent(".sanchr-simulator-db-key")
            .path
    }

    private func readSimulatorMirror(forDatabaseAt path: String) throws -> String? {
        let mirrorPath = simulatorMirrorPath(forDatabaseAt: path)
        guard FileManager.default.fileExists(atPath: mirrorPath) else { return nil }

        let data = try Data(contentsOf: URL(fileURLWithPath: mirrorPath))
        let passphrase = String(data: data, encoding: .utf8)
        SanchrLogger.persistence.info("Simulator DB key mirror present=\(passphrase?.isEmpty == false)")
        return passphrase
    }

    private func writeSimulatorMirror(_ passphrase: String, forDatabaseAt path: String) throws {
        let mirrorURL = URL(fileURLWithPath: simulatorMirrorPath(forDatabaseAt: path))
        let data = Data(passphrase.utf8)
        try data.write(to: mirrorURL, options: .atomic)
        try? (mirrorURL as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        SanchrLogger.persistence.warning("Persisted simulator-only mirrored database key")
    }
    #endif
}

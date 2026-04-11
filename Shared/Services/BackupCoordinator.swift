import Foundation
import LocalAuthentication
import SanchrShared

@Observable
final class BackupCoordinator: @unchecked Sendable {
    private let backupService: BackupArchiveServiceProtocol
    private let recoveryKeyManager: RecoveryKeyManagerProtocol
    private let backupKeyDeriver: BackupKeyDeriverProtocol
    private let currentUserIdProvider: @Sendable () -> String?
    private let postRestore: @Sendable () async -> Void

    private(set) var configuration: BackupConfiguration?
    private(set) var derivedMaterial: DerivedBackupMaterial?
    private(set) var pendingRecoveryKey: String?
    private(set) var errorMessage: String?
    private(set) var isProcessing = false

    init(
        backupService: BackupArchiveServiceProtocol,
        recoveryKeyManager: RecoveryKeyManagerProtocol,
        backupKeyDeriver: BackupKeyDeriverProtocol,
        currentUserIdProvider: @escaping @Sendable () -> String?,
        postRestore: @escaping @Sendable () async -> Void
    ) {
        self.backupService = backupService
        self.recoveryKeyManager = recoveryKeyManager
        self.backupKeyDeriver = backupKeyDeriver
        self.currentUserIdProvider = currentUserIdProvider
        self.postRestore = postRestore
        reload()
    }

    var isEnabled: Bool {
        configuration?.isEnabled ?? false
    }

    func reload() {
        do {
            configuration = try recoveryKeyManager.loadConfiguration()
            if let recoveryKey = try recoveryKeyManager.readRecoveryKey() {
                derivedMaterial = try backupKeyDeriver.deriveMaterial(
                    recoveryKey: recoveryKey,
                    userId: currentUserIdProvider()
                )
            } else {
                derivedMaterial = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareEnableBackups() {
        do {
            pendingRecoveryKey = try recoveryKeyManager.generateRecoveryKey()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmPendingRecoveryKey() async {
        guard let pendingRecoveryKey else { return }

        do {
            let configuration = try recoveryKeyManager.enableBackups(
                with: pendingRecoveryKey,
                lineageId: UUID().uuidString.lowercased()
            )
            self.configuration = configuration
            self.derivedMaterial = try backupKeyDeriver.deriveMaterial(
                recoveryKey: pendingRecoveryKey,
                userId: currentUserIdProvider()
            )
            self.pendingRecoveryKey = nil
            self.errorMessage = nil
            try await backupNow(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelPendingRecoveryKey() {
        pendingRecoveryKey = nil
    }

    func rotateRecoveryKey() {
        prepareEnableBackups()
    }

    func disableBackups() {
        do {
            try recoveryKeyManager.disableBackups()
            configuration = nil
            derivedMaterial = nil
            pendingRecoveryKey = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func backupNow() async throws {
        try await backupNow(force: true)
    }

    func performScheduledBackupIfNeeded() async {
        do {
            try await backupNow(force: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreLatestBackup(with recoveryKeyOverride: String?) async {
        guard !isProcessing else { return }

        do {
            let recoveryKey = try resolvedRecoveryKey(recoveryKeyOverride)
            let material = try backupKeyDeriver.deriveMaterial(
                recoveryKey: recoveryKey,
                userId: currentUserIdProvider()
            )
            isProcessing = true
            errorMessage = nil

            let result = try await backupService.restoreLatestBackup(
                configuration: configuration,
                material: material,
                currentUserId: currentUserIdProvider()
            )
            _ = try recoveryKeyManager.persistRestoredBackup(
                recoveryKey: recoveryKey,
                lineageId: result.lineageID,
                formatVersion: result.formatVersion,
                lastBackupAt: result.backupDate,
                lastBackupContentHash: result.contentHash
            )
            reload()
            await postRestore()
        } catch {
            errorMessage = error.localizedDescription
        }

        isProcessing = false
    }

    func deleteRemoteBackups() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            try await backupService.deleteRemoteBackups(lineageID: configuration?.lineageId)
            try recoveryKeyManager.updateBackupState(lastBackupAt: nil, lastBackupContentHash: nil)
            reload()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealRecoveryKey() async throws -> String {
        try await authenticateForSensitiveAccess()
        guard let recoveryKey = try recoveryKeyManager.readRecoveryKey() else {
            throw AppError.recoveryKeyUnavailable
        }
        return recoveryKey
    }

    /// Returns backup entries sorted descending by committedAt (sort is applied by the service).
    /// Errors are propagated to the caller; BackupView handles them by setting historyState = .failed.
    func listBackups() async throws -> [BackupListEntry] {
        try await backupService.listBackups().sorted { $0.committedAt > $1.committedAt }
    }

    func restoreBackup(backupId: String, with recoveryKeyOverride: String?) async {
        guard !isProcessing else { return }

        do {
            let recoveryKey = try resolvedRecoveryKey(recoveryKeyOverride)
            let material = try backupKeyDeriver.deriveMaterial(
                recoveryKey: recoveryKey,
                userId: currentUserIdProvider()
            )
            isProcessing = true
            errorMessage = nil

            let result = try await backupService.restoreBackup(
                backupId: backupId,
                configuration: configuration,
                material: material,
                currentUserId: currentUserIdProvider()
            )
            _ = try recoveryKeyManager.persistRestoredBackup(
                recoveryKey: recoveryKey,
                lineageId: result.lineageID,
                formatVersion: result.formatVersion,
                lastBackupAt: result.backupDate,
                lastBackupContentHash: result.contentHash
            )
            reload()
            await postRestore()
        } catch {
            errorMessage = error.localizedDescription
        }

        isProcessing = false
    }

    func reportError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func backupNow(force: Bool) async throws {
        guard !isProcessing else { return }
        guard let configuration else { return }
        guard let derivedMaterial else {
            throw AppError.recoveryKeyUnavailable
        }

        isProcessing = true
        defer { isProcessing = false }

        if let outcome = try await backupService.performBackup(
            configuration: configuration,
            material: derivedMaterial,
            currentUserId: currentUserIdProvider(),
            force: force
        ) {
            try recoveryKeyManager.updateBackupState(
                lastBackupAt: outcome.backupDate,
                lastBackupContentHash: outcome.contentHash
            )
            reload()
        }
        errorMessage = nil
    }

    private func resolvedRecoveryKey(_ override: String?) throws -> String {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let stored = try recoveryKeyManager.readRecoveryKey(), !stored.isEmpty else {
            throw AppError.recoveryKeyUnavailable
        }
        return stored
    }

    private func authenticateForSensitiveAccess() async throws {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw AppError.biometricAuthenticationFailed(
                reason: error?.localizedDescription ?? "Authentication is unavailable"
            )
        }

        let success = try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Reveal your Sanchr recovery key"
        )
        guard success else {
            throw AppError.biometricAuthenticationFailed(reason: "Authentication failed")
        }
    }
}

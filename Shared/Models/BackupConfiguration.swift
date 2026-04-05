import Foundation

/// Persisted local configuration for remote encrypted backups.
struct BackupConfiguration: Codable, Equatable, Sendable {
    let isEnabled: Bool
    let lineageId: String
    let formatVersion: Int32
    let recoveryKeyConfirmedAt: Date
    let lastBackupAt: Date?
    let lastBackupContentHash: String?
}

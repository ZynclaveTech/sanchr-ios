import Foundation
import LibSignalClient

struct DerivedBackupMaterial: Equatable, Sendable {
    let metadataKey: Data
    let aesKey: Data?
    let hmacKey: Data?
    let backupId: Data?
}

protocol BackupKeyDeriverProtocol: AnyObject, Sendable {
    func deriveMaterial(recoveryKey: String, userId: String?) throws -> DerivedBackupMaterial
}

final class SignalBackupKeyDeriver: BackupKeyDeriverProtocol, @unchecked Sendable {
    func deriveMaterial(recoveryKey: String, userId: String?) throws -> DerivedBackupMaterial {
        guard AccountEntropyPool.isValid(recoveryKey) else {
            throw AppError.encryptionFailed(reason: "Recovery key is invalid")
        }

        let backupKey = try AccountEntropyPool.deriveBackupKey(recoveryKey)
        let metadataKey = backupKey.deriveLocalBackupMetadataKey()

        guard
            let userId,
            let uuid = UUID(uuidString: userId)
        else {
            return DerivedBackupMaterial(
                metadataKey: metadataKey,
                aesKey: nil,
                hmacKey: nil,
                backupId: nil
            )
        }

        let aci = Aci(fromUUID: uuid)
        let messageBackupKey = try MessageBackupKey(accountEntropy: recoveryKey, aci: aci)
        return DerivedBackupMaterial(
            metadataKey: metadataKey,
            aesKey: messageBackupKey.aesKey,
            hmacKey: messageBackupKey.hmacKey,
            backupId: backupKey.deriveBackupId(aci: aci)
        )
    }
}

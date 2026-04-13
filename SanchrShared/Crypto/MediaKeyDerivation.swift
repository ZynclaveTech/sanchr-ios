import CryptoKit
import Foundation

public protocol MediaKeyDerivationProtocol: Sendable {
    func deriveMediaKey(chainKey: Data, fileHash: Data) -> Data
    func deriveAccessKey(mediaKey: Data, mediaId: String, deviceSecret: Data) -> Data

    /// Derive a vault AccessKey from `dls` (manual upload path).
    /// `AccessK_vault = HKDF(ikm=dls, salt=random, info="sanchr-vault-manual-v1-<id>")`
    func deriveVaultAccessKeyManual(
        deviceSecret: Data,
        salt: Data,
        vaultItemId: String
    ) -> Data

    /// Derive a vault AccessKey from an incoming message's `MediaK_n`
    /// (auto-vault path). Added for forward-compat; v1 has no caller because
    /// auto-vault is deferred to a follow-up plan.
    /// `AccessK_vault = HKDF(ikm=MediaK_n, salt=dls, info="sanchr-vault-from-message-v1-<id>")`
    func deriveVaultAccessKeyFromMessage(
        mediaKey: Data,
        deviceSecret: Data,
        vaultItemId: String
    ) -> Data
}

public final class MediaKeyDerivation: MediaKeyDerivationProtocol, @unchecked Sendable {
    private enum Labels {
        static let mediaKey = "sanchr-media-v1"
        static let accessKey = "sanchr-access-v1"
        static let vaultManual = "sanchr-vault-manual-v1"
        static let vaultFromMessage = "sanchr-vault-from-message-v1"
    }

    public init() {}

    public func deriveMediaKey(chainKey: Data, fileHash: Data) -> Data {
        // Paper: MediaK_n = HKDF(CK_n, file_hash, "media-v1")
        // Backend canonical form: IKM = chainKey || fileHash, salt = empty, info = label
        let concatenatedIKM = chainKey + fileHash
        let ikm = SymmetricKey(data: concatenatedIKM)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: Data(),
            info: Data(Labels.mediaKey.utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }

    public func deriveAccessKey(mediaKey: Data, mediaId: String, deviceSecret: Data) -> Data {
        let ikm = SymmetricKey(data: mediaKey)
        let info = "\(Labels.accessKey)-\(mediaId)"
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: deviceSecret,
            info: Data(info.utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }

    public func deriveVaultAccessKeyManual(
        deviceSecret: Data,
        salt: Data,
        vaultItemId: String
    ) -> Data {
        let ikm = SymmetricKey(data: deviceSecret)
        let info = "\(Labels.vaultManual)-\(vaultItemId)"
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt,
            info: Data(info.utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }

    public func deriveVaultAccessKeyFromMessage(
        mediaKey: Data,
        deviceSecret: Data,
        vaultItemId: String
    ) -> Data {
        let ikm = SymmetricKey(data: mediaKey)
        let info = "\(Labels.vaultFromMessage)-\(vaultItemId)"
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: deviceSecret,
            info: Data(info.utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }
}

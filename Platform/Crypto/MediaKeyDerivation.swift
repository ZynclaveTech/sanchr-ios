import CryptoKit
import Foundation
import SanchrShared

protocol MediaKeyDerivationProtocol: Sendable {
    func deriveMediaKey(chainKey: Data, fileHash: Data) -> Data
    func deriveAccessKey(mediaKey: Data, mediaId: String, deviceSecret: Data) -> Data
}

final class MediaKeyDerivation: MediaKeyDerivationProtocol, @unchecked Sendable {
    private enum Labels {
        static let mediaKey = "sanchr-media-v1"
        static let accessKey = "sanchr-access-v1"
    }

    func deriveMediaKey(chainKey: Data, fileHash: Data) -> Data {
        let ikm = SymmetricKey(data: chainKey)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: fileHash,
            info: Data(Labels.mediaKey.utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }

    func deriveAccessKey(mediaKey: Data, mediaId: String, deviceSecret: Data) -> Data {
        let ikm = SymmetricKey(data: mediaKey)
        let info = "\(Labels.accessKey)-\(mediaId)"
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: deviceSecret,
            info: Data(info.utf8), outputByteCount: 32)
        return derived.withUnsafeBytes { Data($0) }
    }
}

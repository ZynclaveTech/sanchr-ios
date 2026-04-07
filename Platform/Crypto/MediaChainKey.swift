import CryptoKit
import Foundation

struct MediaChainKey: Codable, Sendable {
    var chainKey: Data
    var stepCount: UInt64
    let conversationId: String

    private enum Labels {
        static let chainInit = "sanchr-media-chain-init-v1"
        static let chainAdvance = "sanchr-media-chain-advance-v1"
    }

    static func initialize(deviceSecret: Data, conversationId: String) -> MediaChainKey {
        let ikm = SymmetricKey(data: deviceSecret)
        let initial = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: Data(conversationId.utf8),
            info: Data(Labels.chainInit.utf8), outputByteCount: 32)
        return MediaChainKey(
            chainKey: initial.withUnsafeBytes { Data($0) },
            stepCount: 0, conversationId: conversationId)
    }

    mutating func advance() {
        let ikm = SymmetricKey(data: chainKey)
        let next = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: Data(),
            info: Data(Labels.chainAdvance.utf8), outputByteCount: 32)
        chainKey = next.withUnsafeBytes { Data($0) }
        stepCount += 1
    }
}

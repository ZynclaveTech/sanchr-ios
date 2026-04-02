import Foundation
import CryptoKit

/// Protocol for media file encryption/decryption using AES-GCM.
protocol MediaEncryptionProtocol: Sendable {
    /// Encrypts media data, returning the ciphertext and a randomly generated key.
    func encrypt(data: Data) throws -> (ciphertext: Data, key: Data, iv: Data)

    /// Decrypts media data using the provided key and IV.
    func decrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data

    /// Encrypts a file at the given URL and writes the ciphertext to the output URL.
    func encryptFile(at inputURL: URL, to outputURL: URL) async throws -> (key: Data, iv: Data)

    /// Decrypts a file at the given URL and writes plaintext to the output URL.
    func decryptFile(at inputURL: URL, to outputURL: URL, key: Data, iv: Data) async throws
}

/// AES-256-GCM media encryption implementation.
final class MediaEncryption: MediaEncryptionProtocol, @unchecked Sendable {

    func encrypt(data: Data) throws -> (ciphertext: Data, key: Data, iv: Data) {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()

        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)

        guard let combined = sealedBox.combined else {
            throw AppError.encryptionFailed(reason: "Failed to produce combined ciphertext")
        }

        let keyData = key.withUnsafeBytes { Data($0) }
        let nonceData = Data(nonce)

        return (ciphertext: combined, key: keyData, iv: nonceData)
    }

    func decrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }

    func encryptFile(at inputURL: URL, to outputURL: URL) async throws -> (key: Data, iv: Data) {
        SanchrLogger.media.info("Encrypting file at \(inputURL.lastPathComponent)")

        let inputData = try Data(contentsOf: inputURL)
        let result = try encrypt(data: inputData)
        try result.ciphertext.write(to: outputURL)

        SanchrLogger.media.info("File encrypted: \(result.ciphertext.count) bytes")
        return (key: result.key, iv: result.iv)
    }

    func decryptFile(at inputURL: URL, to outputURL: URL, key: Data, iv: Data) async throws {
        SanchrLogger.media.info("Decrypting file at \(inputURL.lastPathComponent)")

        let ciphertext = try Data(contentsOf: inputURL)
        let plaintext = try decrypt(ciphertext: ciphertext, key: key, iv: iv)
        try plaintext.write(to: outputURL)

        SanchrLogger.media.info("File decrypted: \(plaintext.count) bytes")
    }
}

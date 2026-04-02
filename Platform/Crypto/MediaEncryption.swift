import Foundation
import CryptoKit

/// Protocol for media file encryption/decryption using AES-GCM.
/// Media keys are generated per-file and shared via Signal Protocol messages.
protocol MediaEncryptionProtocol: Sendable {
    /// Encrypts media data, returning the ciphertext and a randomly generated key.
    func encrypt(data: Data) throws -> (ciphertext: Data, key: Data, iv: Data)

    /// Decrypts media data using the provided key and IV.
    func decrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data

    /// Encrypts a file at the given URL and writes the ciphertext to the output URL.
    func encryptFile(at inputURL: URL, to outputURL: URL) async throws -> MediaEncryptionMetadata

    /// Decrypts a file at the given URL and writes plaintext to the output URL.
    func decryptFile(at inputURL: URL, to outputURL: URL, metadata: MediaEncryptionMetadata) async throws
}

/// AES-256-GCM encryption for media files (photos, videos, voice notes).
///
/// Media keys are generated per-file and shared with recipients via Signal Protocol messages.
/// This ensures that even the media CDN cannot read file contents -- only the intended
/// recipient who receives the key via E2EE can decrypt.
final class MediaEncryptor: MediaEncryptionProtocol, @unchecked Sendable {

    // MARK: - Key Generation

    /// Generates a random 256-bit key for encrypting a media file.
    static func generateMediaKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    // MARK: - In-Memory Encryption

    func encrypt(data: Data) throws -> (ciphertext: Data, key: Data, iv: Data) {
        let key = Self.generateMediaKey()
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

    // MARK: - File-Based Encryption

    func encryptFile(at inputURL: URL, to outputURL: URL) async throws -> MediaEncryptionMetadata {
        SanchrLogger.media.info("Encrypting file at \(inputURL.lastPathComponent)")

        let inputData = try Data(contentsOf: inputURL)
        let digest = SHA256.hash(data: inputData)

        let key = Self.generateMediaKey()
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(inputData, using: key, nonce: nonce)

        guard let combined = sealedBox.combined else {
            throw AppError.encryptionFailed(reason: "Failed to produce combined ciphertext for file")
        }
        try combined.write(to: outputURL, options: .atomic)

        let keyData = key.withUnsafeBytes { Data($0) }
        let nonceData = Data(nonce)
        let tagData = Data(sealedBox.tag)

        SanchrLogger.media.info("File encrypted: \(combined.count) bytes")

        return MediaEncryptionMetadata(
            key: keyData,
            nonce: nonceData,
            tag: tagData,
            digest: Data(digest),
            fileSize: Int64(inputData.count)
        )
    }

    func decryptFile(
        at inputURL: URL,
        to outputURL: URL,
        metadata: MediaEncryptionMetadata
    ) async throws {
        SanchrLogger.media.info("Decrypting file at \(inputURL.lastPathComponent)")

        let ciphertext = try Data(contentsOf: inputURL)
        let symmetricKey = SymmetricKey(data: metadata.key)
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)

        // Verify integrity via SHA-256 digest if present.
        if !metadata.digest.isEmpty {
            let computedDigest = Data(SHA256.hash(data: plaintext))
            guard computedDigest == metadata.digest else {
                throw AppError.decryptionFailed(reason: "Media digest mismatch -- file may be corrupted.")
            }
        }

        try plaintext.write(to: outputURL, options: .atomic)
        SanchrLogger.media.info("File decrypted: \(plaintext.count) bytes")
    }
}

// MARK: - Media Encryption Metadata

/// Metadata produced during media encryption, sent alongside the encrypted file URL
/// via a Signal Protocol message so the recipient can decrypt.
struct MediaEncryptionMetadata: Codable, Sendable {
    /// 32-byte AES-256 key.
    let key: Data
    /// 12-byte GCM nonce.
    let nonce: Data
    /// 16-byte GCM authentication tag.
    let tag: Data
    /// SHA-256 digest of the plaintext for integrity verification.
    let digest: Data
    /// Original plaintext file size in bytes.
    let fileSize: Int64
}

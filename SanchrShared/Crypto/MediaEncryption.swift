import CryptoKit
import Foundation

/// Protocol for media file encryption/decryption using AES-GCM.
/// Media keys are generated per-file and shared via Signal Protocol messages.
public protocol MediaEncryptionProtocol: Sendable {
    /// Encrypts media data, returning the ciphertext and a randomly generated key.
    func encrypt(data: Data) throws -> (ciphertext: Data, key: Data, iv: Data)

    /// Encrypts data with an existing key (for thumbnails sharing the main file's key).
    func encrypt(data: Data, withKey key: Data) throws -> Data

    /// Decrypts media data using the provided key and IV.
    func decrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data

    /// Encrypts a file at the given URL and writes the ciphertext to the output URL.
    func encryptFile(at inputURL: URL, to outputURL: URL) async throws -> MediaEncryptionMetadata

    /// Decrypts a file at the given URL and writes plaintext to the output URL.
    func decryptFile(at inputURL: URL, to outputURL: URL, metadata: MediaEncryptionMetadata)
        async throws

    /// Encrypts a file with a pre-derived key instead of generating a random one.
    func encryptFile(at inputURL: URL, to outputURL: URL, withKey keyData: Data) async throws -> MediaEncryptionMetadata
}

/// AES-256-GCM encryption for media files (photos, videos, voice notes).
///
/// Media keys are generated per-file and shared with recipients via Signal Protocol messages.
/// This ensures that even the media CDN cannot read file contents -- only the intended
/// recipient who receives the key via E2EE can decrypt.
public final class MediaEncryptor: MediaEncryptionProtocol, @unchecked Sendable {

    public init() {}

    /// Paper Section 4.2.2: "chunked at 1 MB blocks"
    private static let chunkSize = 1_048_576 // 1 MB

    // MARK: - Key Generation

    /// Generates a random 256-bit key for encrypting a media file.
    public static func generateMediaKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    // MARK: - In-Memory Encryption

    public func encrypt(data: Data) throws -> (ciphertext: Data, key: Data, iv: Data) {
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

    /// Encrypts data with an existing key (e.g. for thumbnails sharing the same key as the main file).
    public func encrypt(data: Data, withKey keyData: Data) throws -> Data {
        let key = SymmetricKey(data: keyData)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
        guard let combined = sealedBox.combined else {
            throw AppError.encryptionFailed(reason: "Failed to produce combined ciphertext")
        }
        return combined
    }

    public func decrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }

    // MARK: - File-Based Encryption

    public func encryptFile(at inputURL: URL, to outputURL: URL) async throws -> MediaEncryptionMetadata {
        SanchrLogger.media.info("Encrypting file at \(inputURL.lastPathComponent)")

        let key = Self.generateMediaKey()
        let nonce = AES.GCM.Nonce()
        let keyData = key.withUnsafeBytes { Data($0) }
        let nonceData = Data(nonce)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: inputURL.path)
        let fileSize = (fileAttributes[.size] as? Int64) ?? 0

        if fileSize > Self.chunkSize {
            // Paper Section 4.2.2: chunked encryption for files > 1 MB
            let result = try encryptFileChunked(
                inputURL: inputURL, outputURL: outputURL,
                key: key, baseNonce: nonce
            )
            return MediaEncryptionMetadata(
                key: keyData, nonce: nonceData,
                tag: result.tag, digest: result.digest,
                fileSize: result.fileSize
            )
        }

        // Single-shot path for small files
        let inputData = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: inputData)
        let sealedBox = try AES.GCM.seal(inputData, using: key, nonce: nonce)

        guard let combined = sealedBox.combined else {
            throw AppError.encryptionFailed(
                reason: "Failed to produce combined ciphertext for file")
        }
        try combined.write(to: outputURL, options: .atomic)

        SanchrLogger.media.info("File encrypted: \(combined.count) bytes")

        return MediaEncryptionMetadata(
            key: keyData, nonce: nonceData,
            tag: Data(sealedBox.tag), digest: Data(digest),
            fileSize: Int64(inputData.count)
        )
    }

    public func encryptFile(at inputURL: URL, to outputURL: URL, withKey keyData: Data) async throws -> MediaEncryptionMetadata {
        SanchrLogger.media.info("Encrypting file with derived key at \(inputURL.lastPathComponent)")

        let key = SymmetricKey(data: keyData)
        let nonce = AES.GCM.Nonce()
        let nonceData = Data(nonce)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: inputURL.path)
        let fileSize = (fileAttributes[.size] as? Int64) ?? 0

        if fileSize > Self.chunkSize {
            // Paper Section 4.2.2: chunked encryption for files > 1 MB
            let result = try encryptFileChunked(
                inputURL: inputURL, outputURL: outputURL,
                key: key, baseNonce: nonce
            )
            return MediaEncryptionMetadata(
                key: keyData, nonce: nonceData,
                tag: result.tag, digest: result.digest,
                fileSize: result.fileSize
            )
        }

        // Single-shot path for small files
        let inputData = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: inputData)
        let sealedBox = try AES.GCM.seal(inputData, using: key, nonce: nonce)

        guard let combined = sealedBox.combined else {
            throw AppError.encryptionFailed(reason: "Failed to produce combined ciphertext for file")
        }
        try combined.write(to: outputURL, options: .atomic)

        return MediaEncryptionMetadata(
            key: keyData, nonce: nonceData,
            tag: Data(sealedBox.tag), digest: Data(digest),
            fileSize: Int64(inputData.count)
        )
    }

    public func decryptFile(
        at inputURL: URL,
        to outputURL: URL,
        metadata: MediaEncryptionMetadata
    ) async throws {
        SanchrLogger.media.info("Decrypting file at \(inputURL.lastPathComponent)")

        let ciphertext = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
        let symmetricKey = SymmetricKey(data: metadata.key)

        // Detect single-shot vs chunked format.
        // Single-shot combined size = nonce(12) + fileSize + tag(16).
        let singleShotSize = 12 + Int(metadata.fileSize) + 16

        let plaintext: Data
        if ciphertext.count == singleShotSize {
            // Single-shot decryption (backward compatible)
            let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
            plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)

            if !metadata.digest.isEmpty {
                let computedDigest = Data(SHA256.hash(data: plaintext))
                guard computedDigest == metadata.digest else {
                    throw AppError.decryptionFailed(
                        reason: "Media digest mismatch -- file may be corrupted.")
                }
            }
        } else {
            // Chunked decryption
            plaintext = try decryptFileChunked(
                ciphertext: ciphertext,
                key: symmetricKey,
                expectedDigest: metadata.digest
            )
        }

        try plaintext.write(to: outputURL, options: .atomic)
        SanchrLogger.media.info("File decrypted: \(plaintext.count) bytes")
    }

    // MARK: - Chunked Encryption Helpers

    /// Encrypts a file in 1 MB chunks using AES-256-GCM.
    /// Each chunk gets its own nonce (incremented from base).
    /// Output format: [chunk1_nonce(12) + chunk1_ciphertext + chunk1_tag(16)] repeated.
    private func encryptFileChunked(
        inputURL: URL,
        outputURL: URL,
        key: SymmetricKey,
        baseNonce: AES.GCM.Nonce
    ) throws -> (digest: Data, fileSize: Int64, tag: Data) {
        let inputData = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
        let digest = Data(SHA256.hash(data: inputData))
        let fileSize = Int64(inputData.count)

        var outputData = Data()
        var chunkIndex: UInt64 = 0
        var offset = 0
        var lastTag = Data()

        while offset < inputData.count {
            let end = min(offset + Self.chunkSize, inputData.count)
            let chunk = inputData[offset..<end]

            let nonce = try Self.deriveChunkNonce(base: baseNonce, index: chunkIndex)
            let sealedBox = try AES.GCM.seal(chunk, using: key, nonce: nonce)

            guard let combined = sealedBox.combined else {
                throw AppError.encryptionFailed(reason: "Chunk \(chunkIndex) failed")
            }
            outputData.append(combined)
            lastTag = Data(sealedBox.tag)

            offset = end
            chunkIndex += 1
        }

        try outputData.write(to: outputURL, options: .atomic)
        SanchrLogger.media.info("Chunked encrypt: \(chunkIndex) chunks, \(outputData.count) bytes")

        return (digest: digest, fileSize: fileSize, tag: lastTag)
    }

    /// Derives a per-chunk nonce using XOR to ensure uniqueness and prevent collisions.
    /// The base nonce has a 4-byte random prefix (bytes 0-3).
    /// Bytes 4-11 are XORed with the big-endian chunk index.
    /// This prevents nonce reuse even for large files (up to 2^64 chunks).
    private static func deriveChunkNonce(base: AES.GCM.Nonce, index: UInt64) throws -> AES.GCM.Nonce {
        var nonceBytes = Array(base) // 12 bytes

        // Convert chunk index to big-endian 8 bytes
        let indexBytes = withUnsafeBytes(of: index.bigEndian) { Array($0) }

        // XOR the counter into nonce bytes 4-11
        // XOR ensures: different indices → different nonces, even if base is reused
        for i in 0..<8 {
            nonceBytes[4 + i] ^= indexBytes[i]
        }

        return try AES.GCM.Nonce(data: Data(nonceBytes))
    }

    /// Decrypts a file that was encrypted in 1 MB chunks.
    private func decryptFileChunked(
        ciphertext: Data,
        key: SymmetricKey,
        expectedDigest: Data
    ) throws -> Data {
        var plaintext = Data()
        var offset = 0
        var chunkIndex: UInt64 = 0

        // Each chunk's combined = nonce(12) + ciphertext + tag(16)
        // Full chunk combined size = 12 + chunkSize + 16
        let fullChunkCombinedSize = 12 + Self.chunkSize + 16

        while offset < ciphertext.count {
            let remaining = ciphertext.count - offset
            let chunkCombinedSize = min(fullChunkCombinedSize, remaining)

            let chunkData = ciphertext[offset..<(offset + chunkCombinedSize)]
            let sealedBox = try AES.GCM.SealedBox(combined: chunkData)
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            plaintext.append(decrypted)

            offset += chunkCombinedSize
            chunkIndex += 1
        }

        if !expectedDigest.isEmpty {
            let computedDigest = Data(SHA256.hash(data: plaintext))
            guard computedDigest == expectedDigest else {
                throw AppError.decryptionFailed(reason: "Media digest mismatch after chunked decryption")
            }
        }

        SanchrLogger.media.info("Chunked decrypt: \(chunkIndex) chunks, \(plaintext.count) bytes")
        return plaintext
    }
}

// MARK: - Media Encryption Metadata

/// Metadata produced during media encryption, sent alongside the encrypted file URL
/// via a Signal Protocol message so the recipient can decrypt.
public struct MediaEncryptionMetadata: Codable, Sendable {
    /// 32-byte AES-256 key.
    public let key: Data
    /// 12-byte GCM nonce.
    public let nonce: Data
    /// 16-byte GCM authentication tag.
    public let tag: Data
    /// SHA-256 digest of the plaintext for integrity verification.
    public let digest: Data
    /// Original plaintext file size in bytes.
    public let fileSize: Int64

    public init(key: Data, nonce: Data, tag: Data, digest: Data, fileSize: Int64) {
        self.key = key
        self.nonce = nonce
        self.tag = tag
        self.digest = digest
        self.fileSize = fileSize
    }
}

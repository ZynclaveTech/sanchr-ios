import CryptoKit
import XCTest
@testable import SanchrShared

final class ChunkedEncryptionTests: XCTestCase {
    let encryptor = MediaEncryptor()
    let tempDir = FileManager.default.temporaryDirectory

    func testSmallFileUsesDirectEncryption() async throws {
        let data = Data(repeating: 0xAB, count: 100)
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + "_small.bin")
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + "_small.enc")
        let decryptedURL = tempDir.appendingPathComponent(UUID().uuidString + "_small.dec")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: decryptedURL)
        }

        try data.write(to: inputURL)
        let metadata = try await encryptor.encryptFile(at: inputURL, to: outputURL)

        // Single-shot: nonce(12) + data(100) + tag(16) = 128
        let ciphertext = try Data(contentsOf: outputURL)
        XCTAssertEqual(ciphertext.count, 128)

        try await encryptor.decryptFile(at: outputURL, to: decryptedURL, metadata: metadata)
        XCTAssertEqual(try Data(contentsOf: decryptedURL), data)
    }

    func testLargeFileUsesChunkedEncryption() async throws {
        // 2.5 MB = 3 chunks (1MB + 1MB + 0.5MB)
        let size = 2_621_440
        let data = Data((0..<size).map { UInt8($0 % 256) })
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + "_large.bin")
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + "_large.enc")
        let decryptedURL = tempDir.appendingPathComponent(UUID().uuidString + "_large.dec")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: decryptedURL)
        }

        try data.write(to: inputURL)
        let metadata = try await encryptor.encryptFile(at: inputURL, to: outputURL)

        // 3 chunks * 28 bytes overhead = 84 bytes overhead
        let ciphertext = try Data(contentsOf: outputURL)
        XCTAssertEqual(ciphertext.count, size + 84)

        try await encryptor.decryptFile(at: outputURL, to: decryptedURL, metadata: metadata)
        XCTAssertEqual(try Data(contentsOf: decryptedURL), data)
    }

    func testChunkedRoundtripWithDerivedKey() async throws {
        let size = 1_500_000 // 1.5 MB = 2 chunks
        let data = Data(repeating: 0xCD, count: size)
        let inputURL = tempDir.appendingPathComponent(UUID().uuidString + "_derived.bin")
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + "_derived.enc")
        let decryptedURL = tempDir.appendingPathComponent(UUID().uuidString + "_derived.dec")
        let keyData = MediaEncryptor.generateMediaKey().withUnsafeBytes { Data($0) }
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: decryptedURL)
        }

        try data.write(to: inputURL)
        let metadata = try await encryptor.encryptFile(at: inputURL, to: outputURL, withKey: keyData)

        try await encryptor.decryptFile(at: outputURL, to: decryptedURL, metadata: metadata)
        XCTAssertEqual(try Data(contentsOf: decryptedURL), data)
    }
}

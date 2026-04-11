// Tests/UnitTests/ProfileCryptoTests.swift
import XCTest
import CryptoKit
import SanchrShared
@testable import Sanchr

final class ProfileCryptoTests: XCTestCase {
    let crypto = ProfileCryptor()
    let key = Data(repeating: 0xAB, count: 32)

    func test_encryptField_producesNonEmptyData() throws {
        let ct = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        XCTAssertFalse(ct.isEmpty)
    }

    func test_encryptField_decryptField_roundtrips() throws {
        let plaintext = "Hello, World! 🌍"
        let ct = try crypto.encryptField(plaintext, profileKey: key, field: .displayName)
        let recovered = try crypto.decryptField(ct, profileKey: key, field: .displayName)
        XCTAssertEqual(recovered, plaintext)
    }

    func test_encryptField_differentFields_produceDifferentCiphertext() throws {
        // Same plaintext + same master key but different field label → different subkey → different ct
        let ct1 = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        let ct2 = try crypto.encryptField("Alice", profileKey: key, field: .bio)
        XCTAssertNotEqual(ct1, ct2, "each ProfileField must derive an independent subkey")
    }

    func test_encryptField_sameInputTwice_differentNonce() throws {
        let ct1 = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        let ct2 = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        XCTAssertNotEqual(ct1, ct2, "AES-GCM must use a fresh random nonce on every call")
    }

    func test_decryptField_tamperedCiphertext_throws() throws {
        var ct = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        ct[ct.count - 1] ^= 0xFF   // corrupt the GCM authentication tag
        XCTAssertThrowsError(
            try crypto.decryptField(ct, profileKey: key, field: .displayName),
            "tampered ciphertext must not decrypt successfully"
        )
    }

    func test_decryptField_wrongKey_throws() throws {
        let ct = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        let wrongKey = Data(repeating: 0x00, count: 32)
        XCTAssertThrowsError(
            try crypto.decryptField(ct, profileKey: wrongKey, field: .displayName),
            "wrong key must not decrypt successfully"
        )
    }
}

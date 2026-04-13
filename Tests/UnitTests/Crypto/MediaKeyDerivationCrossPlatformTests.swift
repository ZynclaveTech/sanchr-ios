import CryptoKit
import XCTest
@testable import SanchrShared

final class MediaKeyDerivationCrossPlatformTests: XCTestCase {

    /// Known-answer test vector matching backend's derive_media_key().
    /// Backend: IKM = chain_key || file_hash (64 bytes), salt = None, info = "sanchr-media-v1"
    func testMediaKeyDerivationMatchesBackend() {
        let chainKey = Data(repeating: 0x11, count: 32)
        let fileHash = Data(repeating: 0x22, count: 32)

        let deriver = MediaKeyDerivation()
        let mediaKey = deriver.deriveMediaKey(chainKey: chainKey, fileHash: fileHash)

        // The correct derivation concatenates IKM, uses no salt:
        let expectedIKM = chainKey + fileHash
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: expectedIKM),
            salt: Data(),
            info: Data("sanchr-media-v1".utf8),
            outputByteCount: 32
        )
        let expectedData = expected.withUnsafeBytes { Data($0) }

        XCTAssertEqual(mediaKey, expectedData, "iOS MediaK must match backend concatenation pattern")
    }

    func testMediaKeyDifferentFilesProduceDifferentKeys() {
        let chainKey = Data(repeating: 0x01, count: 32)
        let hashA = Data(repeating: 0x02, count: 32)
        let hashB = Data(repeating: 0x03, count: 32)

        let deriver = MediaKeyDerivation()
        XCTAssertNotEqual(
            deriver.deriveMediaKey(chainKey: chainKey, fileHash: hashA),
            deriver.deriveMediaKey(chainKey: chainKey, fileHash: hashB)
        )
    }

    func testAccessKeyDerivationUsesCorrectHKDFStructure() {
        let mediaKey = Data(repeating: 0x42, count: 32)
        let deviceSecret = Data(repeating: 0x01, count: 32)
        let mediaId = "test-media-123"

        let deriver = MediaKeyDerivation()
        let accessKey = deriver.deriveAccessKey(mediaKey: mediaKey, mediaId: mediaId, deviceSecret: deviceSecret)

        // Correct: IKM = mediaKey || deviceSecret, salt = empty, info = "sanchr-access-v1-<mediaId>"
        let concatenatedIKM = mediaKey + deviceSecret
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: concatenatedIKM),
            salt: Data(),
            info: Data("sanchr-access-v1-\(mediaId)".utf8),
            outputByteCount: 32
        )
        let expectedData = expected.withUnsafeBytes { Data($0) }

        XCTAssertEqual(accessKey, expectedData, "iOS AccessK must use concatenation-as-IKM pattern")
    }

    func testAccessKeyDeviceIsolation() {
        let mediaKey = Data(repeating: 0x42, count: 32)
        let deviceA = Data(repeating: 0x01, count: 32)
        let deviceB = Data(repeating: 0x02, count: 32)

        let deriver = MediaKeyDerivation()
        let keyA = deriver.deriveAccessKey(mediaKey: mediaKey, mediaId: "m1", deviceSecret: deviceA)
        let keyB = deriver.deriveAccessKey(mediaKey: mediaKey, mediaId: "m1", deviceSecret: deviceB)

        XCTAssertNotEqual(keyA, keyB, "Different device secrets must produce different AccessK")
    }
}

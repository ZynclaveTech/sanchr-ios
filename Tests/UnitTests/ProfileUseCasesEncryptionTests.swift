import XCTest
import SanchrShared
@testable import Sanchr

// MARK: - Stub

/// Captures what UpdateProfile sends to the data layer.
private final class StubProfileDataSource: ProfileDataSourceProtocol, @unchecked Sendable {
    var capturedProfileKey: Data?
    var capturedEncryptedDisplayName: Data?
    var capturedEncryptedBio: Data?
    var capturedEncryptedAvatarURL: Data?

    func updateProfile(
        name: String,
        avatarURL: String,
        status: String,
        profileKey: Data,
        encryptedDisplayName: Data,
        encryptedBio: Data,
        encryptedAvatarURL: Data
    ) async throws -> Sanchr_Settings_ProfileResponse {
        capturedProfileKey = profileKey
        capturedEncryptedDisplayName = encryptedDisplayName
        capturedEncryptedBio = encryptedBio
        capturedEncryptedAvatarURL = encryptedAvatarURL
        var response = Sanchr_Settings_ProfileResponse()
        response.displayName = name
        return response
    }

    func uploadAvatar(imageData: Data) async throws -> String { "" }
    func getProfile() async throws -> Sanchr_Settings_ProfileResponse {
        Sanchr_Settings_ProfileResponse()
    }
}

// MARK: - Tests

final class ProfileUseCasesEncryptionTests: XCTestCase {

    private func makeSUT() -> (
        sut: ProfileUseCases.UpdateProfile,
        dataSource: StubProfileDataSource,
        keychain: MockKeychainService
    ) {
        let dataSource = StubProfileDataSource()
        let keychain   = MockKeychainService()
        let sut = ProfileUseCases.UpdateProfile(
            profileDataSource: dataSource,
            profileKeyStore: ProfileKeyStore(keychain: keychain),
            profileCrypto: ProfileCryptor()
        )
        return (sut, dataSource, keychain)
    }

    func test_execute_sends32ByteProfileKey() async throws {
        let (sut, dataSource, _) = makeSUT()
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "")
        XCTAssertEqual(dataSource.capturedProfileKey?.count, 32)
    }

    func test_execute_encryptedDisplayName_isNotEqualToPlaintext() async throws {
        let (sut, dataSource, _) = makeSUT()
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "")
        let encrypted = try XCTUnwrap(dataSource.capturedEncryptedDisplayName)
        XCTAssertFalse(encrypted.isEmpty)
        XCTAssertNotEqual(encrypted, "Alice".data(using: .utf8),
                          "ciphertext must not equal the plaintext UTF-8 bytes")
    }

    func test_execute_profileKey_isStable_acrossMultipleCalls() async throws {
        let (sut, dataSource, _) = makeSUT()
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "")
        let key1 = dataSource.capturedProfileKey
        _ = try await sut.execute(name: "Bob", avatarURL: "", status: "")
        let key2 = dataSource.capturedProfileKey
        XCTAssertEqual(key1, key2, "the profile key must not rotate between calls")
    }

    func test_execute_emptyStatus_sendsEmptyEncryptedBio() async throws {
        let (sut, dataSource, _) = makeSUT()
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "")
        XCTAssertEqual(dataSource.capturedEncryptedBio, Data(),
                       "empty status must not produce ciphertext")
    }
}

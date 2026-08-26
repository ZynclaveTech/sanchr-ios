import XCTest
import SanchrShared
@testable import Sanchr

// MARK: - Stub

/// Captures what UpdateProfile sends to the data layer.
private final class StubProfileDataSource: ProfileDataSourceProtocol, @unchecked Sendable {
    var capturedAvatarURL: String?
    var capturedEncryptedDisplayName: Data?
    var capturedEncryptedBio: Data?
    var capturedEncryptedAvatarURL: Data?

    func updateProfile(
        avatarURL: String,
        encryptedDisplayName: Data,
        encryptedBio: Data,
        encryptedAvatarURL: Data
    ) async throws -> Sanchr_Settings_ProfileResponse {
        capturedAvatarURL = avatarURL
        capturedEncryptedDisplayName = encryptedDisplayName
        capturedEncryptedBio = encryptedBio
        capturedEncryptedAvatarURL = encryptedAvatarURL
        return Sanchr_Settings_ProfileResponse()
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

    /// The upload surface must carry no way to read what it protects. This
    /// previously asserted the opposite — that a 32-byte Profile Key *was* sent —
    /// which locked in the defect: the server received the key and the ciphertext
    /// together, so the encryption protected nothing from it.
    func test_execute_neverUploadsProfileKeyOrPlaintext() async throws {
        let (sut, dataSource, _) = makeSUT()
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "Hiking")

        let mirror = Mirror(reflecting: dataSource)
        let captured = Set(mirror.children.compactMap(\.label))
        XCTAssertFalse(
            captured.contains("capturedProfileKey"),
            "the Profile Key must not be part of the upload surface at all")

        let name = try XCTUnwrap(dataSource.capturedEncryptedDisplayName)
        let bio = try XCTUnwrap(dataSource.capturedEncryptedBio)
        XCTAssertNil(name.range(of: Data("Alice".utf8)), "plaintext name must not appear in the upload")
        XCTAssertNil(bio.range(of: Data("Hiking".utf8)), "plaintext bio must not appear in the upload")
    }

    func test_execute_encryptedDisplayName_isNotEqualToPlaintext() async throws {
        let (sut, dataSource, _) = makeSUT()
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "")
        let encrypted = try XCTUnwrap(dataSource.capturedEncryptedDisplayName)
        XCTAssertFalse(encrypted.isEmpty)
        XCTAssertNotEqual(encrypted, "Alice".data(using: .utf8),
                          "ciphertext must not equal the plaintext UTF-8 bytes")
    }

    /// The key must stay stable so contacts that already received it over the
    /// Signal session can keep decrypting after a later profile edit.
    func test_execute_profileKey_isStable_acrossMultipleCalls() async throws {
        let (sut, _, keychain) = makeSUT()
        let store = ProfileKeyStore(keychain: keychain)
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "")
        let key1 = try store.ownProfileKey()
        _ = try await sut.execute(name: "Bob", avatarURL: "", status: "")
        let key2 = try store.ownProfileKey()
        XCTAssertEqual(key1, key2, "the profile key must not rotate between calls")
    }

    func test_execute_emptyStatus_sendsEmptyEncryptedBio() async throws {
        let (sut, dataSource, _) = makeSUT()
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "")
        XCTAssertEqual(dataSource.capturedEncryptedBio, Data(),
                       "empty status must not produce ciphertext")
    }
}

// MARK: - Profile key distribution channel

/// The Profile Key must travel only over the Signal session. These pin the
/// wire-level contract that `MessageRepository.sendProfileKey` and the sealed
/// decode path agree on, so a rename or a size change cannot silently split them.
final class ProfileKeyDistributionTests: XCTestCase {

    func test_contentType_isStableWireIdentifier() {
        XCTAssertEqual(MessageRepositoryImpl.profileKeyContentType, "profile-key/v1")
    }

    /// A Profile Key is exactly 32 bytes; the receive path rejects anything else,
    /// so the generator and the validator must not drift apart.
    func test_generatedProfileKey_matchesLengthTheReceiverAccepts() throws {
        let store = ProfileKeyStore(keychain: MockKeychainService())
        XCTAssertEqual(try store.ownProfileKey().count, 32)
    }

    /// Round-trip: a key delivered over the session and stored locally is the key
    /// that decrypts that contact's fields. This is the property the server can no
    /// longer satisfy, which is the point of the change.
    func test_locallyDeliveredKey_decryptsContactFields() throws {
        let crypto = ProfileCryptor()
        let senderStore = ProfileKeyStore(keychain: MockKeychainService())
        let senderKey = try senderStore.ownProfileKey()

        let ciphertext = try crypto.encryptField(
            "Alice", profileKey: senderKey, field: .displayName)

        // Receiver stores the key as if it arrived in a profile-key/v1 envelope.
        let receiverStore = ProfileKeyStore(keychain: MockKeychainService())
        try receiverStore.saveContactProfileKey(senderKey, forUserId: "alice")

        let known = try XCTUnwrap(receiverStore.contactProfileKey(forUserId: "alice"))
        let decrypted = try crypto.decryptField(
            ciphertext, profileKey: known, field: .displayName)
        XCTAssertEqual(decrypted, "Alice")
    }
}

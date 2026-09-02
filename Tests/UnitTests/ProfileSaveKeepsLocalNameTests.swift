import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// Saving the profile must not replace what the user typed with whatever the
/// server echoes: the server only ever holds ciphertext, so its "name" is a
/// placeholder — and a placeholder in the session sends the user back through
/// onboarding.
@MainActor
final class ProfileSaveKeepsLocalNameTests: XCTestCase {

    private final class PlaceholderEchoingDataSource: ProfileDataSourceProtocol, @unchecked Sendable {
        func updateProfile(
            avatarURL: String, encryptedDisplayName: Data, encryptedBio: Data,
            encryptedAvatarURL: Data, profileKeyVersion: Data
        ) async throws -> Sanchr_Settings_ProfileResponse {
            var response = Sanchr_Settings_ProfileResponse()
            response.displayName = User.serverPlaceholderDisplayName
            response.statusText = ""
            return response
        }
        func uploadAvatar(imageData: Data) async throws -> String { "" }
        func getProfile() async throws -> Sanchr_Settings_ProfileResponse { Sanchr_Settings_ProfileResponse() }
    }

    func testTheTypedNameSurvivesAPlaceholderReply() async throws {
        let storage = MockSecureStorage()
        let session = SessionService(secureStorage: storage, authRepository: MockAuthRepository(), privacySettings: PrivacySettingsCache())
        try await session.storeTokens(AuthTokens(
            accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600),
            userId: "user-1", displayName: "Asha", phoneNumber: "+10000000000", avatarURL: "", deviceId: "1"
        ))

        let viewModel = ProfileViewModel()
        viewModel.displayName = "Asha Rao"
        await viewModel.saveProfile(
            profileDataSource: PlaceholderEchoingDataSource(),
            profileKeyStore: ProfileKeyStore(keychain: MockKeychainService()),
            profileCrypto: ProfileCryptor(),
            sessionService: session
        )

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.displayName, "Asha Rao")
        XCTAssertEqual(session.currentDisplayName, "Asha Rao")
        XCTAssertNotEqual(session.currentDisplayName, User.serverPlaceholderDisplayName)
    }
}

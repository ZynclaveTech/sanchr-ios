import Foundation
import UIKit
import SanchrShared

/// View model for the profile screen.
/// @Observable with user profile state, edit mode, avatar picker, and gRPC sync.
@MainActor
@Observable
final class ProfileViewModel {

    // MARK: - Profile State

    var userId: String = ""
    var displayName: String = "Sanchr User"
    var phoneNumber: String = "+1 234 567 890"
    var statusText: String = ""
    var avatarURL: String = ""
    var isEditing: Bool = false
    var isSaving: Bool = false
    var isUploadingAvatar: Bool = false
    var errorMessage: String?

    // MARK: - Original Values (for change detection)

    private var originalDisplayName: String = ""
    private var originalStatusText: String = ""
    private var originalAvatarURL: String = ""

    /// Saving an empty name is not a no-op: the root view treats a nameless
    /// session as unfinished onboarding and sends the user back through it.
    var hasDisplayName: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasChanges: Bool {
        displayName != originalDisplayName || statusText != originalStatusText
            || avatarURL != originalAvatarURL
    }

    // MARK: - Load Profile

    func loadProfile(sessionService: SessionService) async {
        userId = sessionService.currentUserId ?? ""
        if let name = sessionService.currentDisplayName, !name.isEmpty {
            displayName = name
        }
        if let phone = sessionService.currentPhoneNumber, !phone.isEmpty {
            phoneNumber = phone
        }
        if let avatar = sessionService.currentAvatarURL, !avatar.isEmpty {
            avatarURL = avatar
        }
        if let status = sessionService.currentStatusText {
            statusText = status
        }
        originalDisplayName = displayName
        originalStatusText = statusText
        originalAvatarURL = avatarURL
    }

    // MARK: - Save Profile

    func saveProfile(
        profileDataSource: ProfileDataSourceProtocol,
        profileKeyStore: ProfileKeyStoreProtocol,
        profileCrypto: ProfileCryptoProtocol,
        sessionService: SessionService
    ) async {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter a display name."
            return
        }

        isSaving = true
        defer { isSaving = false }

        let useCase = ProfileUseCases.UpdateProfile(
            profileDataSource: profileDataSource,
            profileKeyStore: profileKeyStore,
            profileCrypto: profileCrypto
        )

        do {
            let response = try await useCase.execute(
                name: trimmedName,
                avatarURL: avatarURL,
                status: statusText
            )

            // The reply has nothing to say about these. The request carried
            // only ciphertext, so the server's copy of the name is its
            // placeholder ("Sanchr User"); adopting it here wrote that into
            // the session, the root view stopped seeing a completed profile,
            // and every edit sent the user back to the onboarding name step.
            // What the user typed is the truth, as it is in onboarding.
            _ = response

            originalDisplayName = displayName
            originalStatusText  = statusText
            originalAvatarURL   = avatarURL

            sessionService.updateProfile(displayName: displayName, avatarURL: avatarURL, statusText: statusText)

            isEditing     = false
            errorMessage  = nil

            SanchrLogger.network.info("Profile saved successfully")
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    // MARK: - Upload Avatar

    func uploadAvatar(
        image: UIImage,
        profileDataSource: ProfileDataSource,
        profileKeyStore: ProfileKeyStoreProtocol,
        profileCrypto: ProfileCryptoProtocol,
        mediaManager: MediaManagerProtocol,
        sessionService: SessionService
    ) async {
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }

        let useCase = ProfileUseCases.UploadAvatar(
            profileDataSource: profileDataSource,
            mediaManager: mediaManager
        )

        do {
            let newURL = try await useCase.execute(image: image)
            avatarURL = newURL
            SanchrLogger.media.info("Avatar URL updated")

            // Persist to server immediately — includes profile-field encryption.
            await saveProfile(
                profileDataSource: profileDataSource,
                profileKeyStore: profileKeyStore,
                profileCrypto: profileCrypto,
                sessionService: sessionService
            )
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    // MARK: - Cancel Edit

    func cancelEdit() {
        displayName = originalDisplayName
        statusText = originalStatusText
        avatarURL = originalAvatarURL
        isEditing = false
    }
}

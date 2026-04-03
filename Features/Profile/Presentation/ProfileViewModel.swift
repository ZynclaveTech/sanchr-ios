import Foundation
import UIKit

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
        originalDisplayName = displayName
        originalStatusText = statusText
        originalAvatarURL = avatarURL
    }

    // MARK: - Save Profile

    func saveProfile(profileDataSource: ProfileDataSource, sessionService: SessionService) async {
        isSaving = true
        defer { isSaving = false }

        let useCase = ProfileUseCases.UpdateProfile(profileDataSource: profileDataSource)

        do {
            let response = try await useCase.execute(
                name: displayName,
                avatarURL: avatarURL,
                status: statusText
            )

            // Update with server-confirmed values
            displayName = response.displayName.isEmpty ? displayName : response.displayName
            avatarURL = response.avatarURL.isEmpty ? avatarURL : response.avatarURL
            statusText = response.statusText.isEmpty ? statusText : response.statusText

            // Update originals
            originalDisplayName = displayName
            originalStatusText = statusText
            originalAvatarURL = avatarURL

            // Sync back to session so Settings and other screens reflect changes
            sessionService.updateProfile(displayName: displayName, avatarURL: avatarURL)

            isEditing = false
            errorMessage = nil

            SanchrLogger.network.info("Profile saved successfully")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Upload Avatar

    func uploadAvatar(
        image: UIImage,
        profileDataSource: ProfileDataSource,
        mediaManager: MediaManagerProtocol
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
        } catch {
            errorMessage = error.localizedDescription
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

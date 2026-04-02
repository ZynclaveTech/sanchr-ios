import Foundation

/// View model for the profile screen.
@Observable
final class ProfileViewModel {
    var displayName: String = "Sanchr User"
    var phoneNumber: String = "+1 234 567 890"
    var bio: String = ""
    var isSaving: Bool = false
    var errorMessage: String?

    private var originalDisplayName: String = ""
    private var originalBio: String = ""

    var hasChanges: Bool {
        displayName != originalDisplayName || bio != originalBio
    }

    func loadProfile() async {
        // TODO: Load from session service / contact repository
        originalDisplayName = displayName
        originalBio = bio
    }

    func saveProfile(contactRepository: ContactRepositoryProtocol) async {
        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await contactRepository.updateProfile(
                displayName: displayName,
                bio: bio.isEmpty ? nil : bio,
                avatarData: nil
            )
            originalDisplayName = displayName
            originalBio = bio
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

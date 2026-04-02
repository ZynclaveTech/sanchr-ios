import Foundation

/// Domain use cases for profile operations.
enum ProfileUseCases {

    /// Updates the current user's profile.
    struct UpdateProfile: Sendable {
        private let contactRepository: ContactRepositoryProtocol

        init(contactRepository: ContactRepositoryProtocol) {
            self.contactRepository = contactRepository
        }

        func execute(displayName: String?, bio: String?, avatarData: Data?) async throws -> User {
            try await contactRepository.updateProfile(
                displayName: displayName,
                bio: bio,
                avatarData: avatarData
            )
        }
    }
}

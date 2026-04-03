import Foundation
import UIKit

/// Domain use cases for profile operations.
enum ProfileUseCases {

    /// Updates the user's profile (display name, status, avatar URL).
    struct UpdateProfile: Sendable {
        private let profileDataSource: ProfileDataSource

        init(profileDataSource: ProfileDataSource) {
            self.profileDataSource = profileDataSource
        }

        /// Updates name and/or status on the server.
        func execute(
            name: String,
            avatarURL: String,
            status: String
        ) async throws -> Vync_Settings_ProfileResponse {
            try await profileDataSource.updateProfile(
                name: name,
                avatarURL: avatarURL,
                status: status
            )
        }
    }

    /// Uploads an avatar image, then updates the profile with the new URL.
    struct UploadAvatar: Sendable {
        private let profileDataSource: ProfileDataSource
        private let mediaManager: MediaManagerProtocol

        init(profileDataSource: ProfileDataSource, mediaManager: MediaManagerProtocol) {
            self.profileDataSource = profileDataSource
            self.mediaManager = mediaManager
        }

        /// Compresses and uploads the avatar image. Returns the new avatar URL.
        func execute(image: UIImage) async throws -> String {
            // 1. Compress to reasonable size
            let compressed = try await mediaManager.compressImage(image, maxSizeKB: 512)

            // 2. Upload to S3 via presigned URL
            let avatarURL = try await profileDataSource.uploadAvatar(imageData: compressed)

            SanchrLogger.media.info("Avatar uploaded: \(avatarURL.prefix(40))...")
            return avatarURL
        }
    }
}

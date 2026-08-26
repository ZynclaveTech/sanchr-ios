import CryptoKit
import Foundation
import UIKit
import SanchrShared

/// Domain use cases for profile operations.
enum ProfileUseCases {

    /// Updates the user's profile, encrypting fields before sending.
    struct UpdateProfile: Sendable {
        private let profileDataSource: ProfileDataSourceProtocol
        private let profileKeyStore: ProfileKeyStoreProtocol
        private let profileCrypto: ProfileCryptoProtocol

        init(
            profileDataSource: ProfileDataSourceProtocol,
            profileKeyStore: ProfileKeyStoreProtocol,
            profileCrypto: ProfileCryptoProtocol
        ) {
            self.profileDataSource = profileDataSource
            self.profileKeyStore = profileKeyStore
            self.profileCrypto = profileCrypto
        }

        /// Encrypts name/bio/avatarURL with the local Profile Key and uploads only the
        /// ciphertext. The key itself never reaches the server — it is delivered to
        /// contacts over the Signal session by `distributeProfileKey`.
        func execute(
            name: String,
            avatarURL: String,
            status: String
        ) async throws -> Sanchr_Settings_ProfileResponse {
            let profileKey = try profileKeyStore.ownProfileKey()

            let encryptedName = try profileCrypto.encryptField(
                name, profileKey: profileKey, field: .displayName)
            let encryptedBio: Data = status.isEmpty
                ? Data()
                : (try profileCrypto.encryptField(status, profileKey: profileKey, field: .bio))
            let encryptedAvatarURL: Data = avatarURL.isEmpty
                ? Data()
                : (try profileCrypto.encryptField(avatarURL, profileKey: profileKey, field: .avatarURL))

            // Version = first 16 bytes of SHA-256(profileKey). Lets a client later
            // notice the server's ciphertext was encrypted under a key it no
            // longer holds (a reinstall) and re-upload, rather than stay nameless.
            let version = Data(SHA256.hash(data: profileKey).prefix(16))

            return try await profileDataSource.updateProfile(
                avatarURL: avatarURL,
                encryptedDisplayName: encryptedName,
                encryptedBio: encryptedBio,
                encryptedAvatarURL: encryptedAvatarURL,
                profileKeyVersion: version
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

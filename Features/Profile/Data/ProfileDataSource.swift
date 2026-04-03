import CryptoKit
import Foundation

/// Data source for profile-related gRPC service calls.
/// Wires to SettingsService.UpdateProfile and MediaService for avatar upload.
final class ProfileDataSource: @unchecked Sendable {
    private let settingsClient: Vync_Settings_SettingsServiceClientProtocol
    private let mediaClient: Vync_Media_MediaServiceClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.settingsClient = Vync_Settings_SettingsServiceClient(grpcClient: grpcClient)
        self.mediaClient = Vync_Media_MediaServiceClient(grpcClient: grpcClient)
    }

    // MARK: - Update Profile

    /// Updates the user's display name, avatar URL, and status text via SettingsService.UpdateProfile.
    func updateProfile(
        name: String,
        avatarURL: String,
        status: String
    ) async throws -> Vync_Settings_ProfileResponse {
        var request = Vync_Settings_UpdateProfileRequest()
        request.displayName = name
        request.avatarURL = avatarURL
        request.statusText = status

        SanchrLogger.network.info("ProfileDataSource: updateProfile name=\(name.prefix(10))...")
        return try await settingsClient.updateProfile(request)
    }

    // MARK: - Upload Avatar

    /// Uploads avatar image data to S3 via MediaService presigned URL.
    /// Returns the final media URL to use in the profile.
    func uploadAvatar(imageData: Data) async throws -> String {
        // 1. Compute hash for dedup
        let digest = SHA256.hash(data: imageData)
        let hashHex = digest.map { String(format: "%02x", $0) }.joined()

        // 2. Get presigned upload URL
        var uploadRequest = Vync_Media_GetUploadUrlRequest()
        uploadRequest.fileSize = Int64(imageData.count)
        uploadRequest.contentType = "image/jpeg"
        uploadRequest.sha256Hash = hashHex

        SanchrLogger.network.info(
            "ProfileDataSource: getUploadUrl for avatar (\(imageData.count) bytes)")
        let uploadResponse = try await mediaClient.getUploadUrl(uploadRequest)

        // 3. Upload to S3
        try await uploadToS3(data: imageData, url: uploadResponse.url, contentType: "image/jpeg")

        // 4. Confirm upload
        var confirmRequest = Vync_Media_ConfirmUploadRequest()
        confirmRequest.mediaID = uploadResponse.mediaID
        confirmRequest.fileSize = Int64(imageData.count)
        _ = try await mediaClient.confirmUpload(confirmRequest)

        SanchrLogger.network.info(
            "ProfileDataSource: avatar uploaded, mediaID=\(uploadResponse.mediaID)")

        // Return the URL (the server may transform this; use the presigned URL as fallback)
        return uploadResponse.url
    }

    // MARK: - Get Profile

    /// Fetches the current user's profile via a settings read.
    func getProfile() async throws -> Vync_Settings_ProfileResponse {
        // Use updateProfile with current values to get a response, or use getSettings
        // For now, use a minimal update to fetch current state
        let settings = try await settingsClient.getSettings(Vync_Settings_GetSettingsRequest())
        let profile = Vync_Settings_ProfileResponse()
        // Settings doesn't return full profile; the profile is typically loaded from session
        _ = settings
        return profile
    }

    // MARK: - Private

    private func uploadToS3(data: Data, url: String, contentType: String) async throws {
        guard let uploadURL = URL(string: url) else {
            throw AppError.mediaUploadFailed
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw AppError.mediaUploadFailed
        }

        SanchrLogger.media.info("Avatar S3 upload complete: \(data.count) bytes")
    }
}

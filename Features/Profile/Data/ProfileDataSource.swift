import CryptoKit
import Foundation
import SanchrShared

// MARK: - Protocol (for testability)

protocol ProfileDataSourceProtocol: AnyObject, Sendable {
    func updateProfile(
        avatarURL: String,
        encryptedDisplayName: Data,
        encryptedBio: Data,
        encryptedAvatarURL: Data,
        profileKeyVersion: Data
    ) async throws -> Sanchr_Settings_ProfileResponse

    func uploadAvatar(imageData: Data) async throws -> String
    func getProfile() async throws -> Sanchr_Settings_ProfileResponse
}

// MARK: - Concrete implementation

/// Data source for profile-related gRPC service calls.
/// Wires to SettingsService.UpdateProfile and MediaService for avatar upload.
final class ProfileDataSource: ProfileDataSourceProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    private var settingsClient: Sanchr_Settings_SettingsServiceAsyncClientProtocol {
        grpcClient.settingsService
    }

    private var mediaClient: Sanchr_Media_MediaServiceAsyncClientProtocol {
        grpcClient.mediaService
    }

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    // MARK: - Update Profile

    /// Updates the user's display name, avatar URL, and status text via SettingsService.UpdateProfile.
    /// Also sends encrypted profile fields (AES-256-GCM); server stores them as opaque blobs.
    func updateProfile(
        avatarURL: String,
        encryptedDisplayName: Data,
        encryptedBio: Data,
        encryptedAvatarURL: Data,
        profileKeyVersion: Data
    ) async throws -> Sanchr_Settings_ProfileResponse {
        var request = Sanchr_Settings_UpdateProfileRequest()
        // Only ciphertext leaves the device. The Profile Key is distributed to
        // contacts over the Signal session (MessageRepository.sendProfileKey); it is
        // never uploaded, because sending it alongside the ciphertext it protects
        // handed the server both halves. displayName and statusText are likewise no
        // longer sent in the clear — doing so made the encryption decorative
        // regardless of how the key travelled.
        request.avatarURL = avatarURL
        request.encryptedDisplayName = encryptedDisplayName
        request.encryptedBio = encryptedBio
        request.encryptedAvatarURL = encryptedAvatarURL
        // Records which Profile Key this ciphertext was made with, so a client
        // can later detect that the server's copy predates the key it now holds.
        request.profileKeyVersion = profileKeyVersion

        SanchrLogger.network.info("ProfileDataSource: updateProfile (encrypted fields only)")
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
        var uploadRequest = Sanchr_Media_GetUploadUrlRequest()
        uploadRequest.fileSize = Int64(imageData.count)
        uploadRequest.contentType = "image/jpeg"
        uploadRequest.sha256Hash = hashHex
        uploadRequest.purpose = .avatar

        SanchrLogger.network.info(
            "ProfileDataSource: getUploadUrl for avatar (\(imageData.count) bytes)")
        let uploadResponse: Sanchr_Media_PresignedUrlResponse
        do {
            uploadResponse = try await mediaClient.getUploadUrl(uploadRequest)
        } catch {
            SanchrLogger.network.error("ProfileDataSource: getUploadUrl failed: \(error)")
            throw error
        }

        // 3. Upload to S3
        do {
            try await uploadToS3(data: imageData, url: uploadResponse.url, contentType: "image/jpeg", acl: "public-read")
        } catch {
            SanchrLogger.network.error("ProfileDataSource: S3 upload failed: \(error)")
            throw error
        }

        // 4. Confirm upload
        var confirmRequest = Sanchr_Media_ConfirmUploadRequest()
        confirmRequest.mediaID = uploadResponse.mediaID
        confirmRequest.fileSize = Int64(imageData.count)
        do {
            _ = try await mediaClient.confirmUpload(confirmRequest)
        } catch {
            SanchrLogger.network.error("ProfileDataSource: confirmUpload failed: \(error)")
            throw error
        }

        SanchrLogger.network.info(
            "ProfileDataSource: avatar uploaded, mediaID=\(uploadResponse.mediaID)")

        // Prefer the CDN display URL from the server.
        // The server sometimes returns a relative path (e.g. "/avatars/…") instead of
        // a full https:// URL. Resolve it against the configured mediaBaseURL so that
        // callers always receive an absolute URL that URLSession can load.
        if !uploadResponse.displayURL.isEmpty {
            if let absolute = URL(string: uploadResponse.displayURL),
               absolute.scheme != nil
            {
                // Already absolute — return as-is.
                return absolute.absoluteString
            }
            // Relative path — resolve against the CDN base.
            let base = AppConfiguration.current.mediaBaseURL
            // Ensure the path starts with "/" before appending so we don't
            // accidentally double-up the base path component.
            let relativePath = uploadResponse.displayURL.hasPrefix("/")
                ? uploadResponse.displayURL
                : "/" + uploadResponse.displayURL
            if let resolved = URL(string: relativePath, relativeTo: base)?.absoluteURL {
                SanchrLogger.network.info(
                    "ProfileDataSource: resolved relative displayURL → \(resolved.absoluteString.prefix(60))…")
                return resolved.absoluteString
            }
        }

        // Fall back: strip presigned query params from the upload URL.
        if var components = URLComponents(string: uploadResponse.url) {
            components.queryItems = nil
            if let permanentURL = components.url?.absoluteString {
                return permanentURL
            }
        }
        return uploadResponse.url
    }

    // MARK: - Get Profile

    /// Fetches the current user's profile via a settings read.
    func getProfile() async throws -> Sanchr_Settings_ProfileResponse {
        // Use updateProfile with current values to get a response, or use getSettings
        // For now, use a minimal update to fetch current state
        let settings = try await settingsClient.getSettings(Sanchr_Settings_GetSettingsRequest())
        let profile = Sanchr_Settings_ProfileResponse()
        // Settings doesn't return full profile; the profile is typically loaded from session
        _ = settings
        return profile
    }

    // MARK: - Private

    private func uploadToS3(data: Data, url: String, contentType: String, acl: String? = nil) async throws {
        guard let uploadURL = URL(string: url) else {
            throw AppError.mediaUploadFailed
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        if let acl = acl {
            request.setValue(acl, forHTTPHeaderField: "x-amz-acl")
        }
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? "no body"
            SanchrLogger.network.error("S3 PUT failed: HTTP \(statusCode) — \(body)")
            throw AppError.mediaUploadFailed
        }

        SanchrLogger.media.info("Avatar S3 upload complete: \(data.count) bytes")
    }
}

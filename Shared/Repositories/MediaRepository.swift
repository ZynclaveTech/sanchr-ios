import Foundation

/// Protocol defining media upload/download operations via presigned URLs.
protocol MediaRepositoryProtocol: AnyObject, Sendable {
    /// Gets a presigned URL for uploading an encrypted media blob.
    func getUploadUrl(fileSize: Int64, contentType: String, sha256Hash: String) async throws -> Vync_Media_PresignedUrlResponse

    /// Gets a presigned URL for downloading an encrypted media blob.
    func getDownloadUrl(mediaId: String) async throws -> Vync_Media_PresignedUrlResponse

    /// Confirms that a media upload completed successfully.
    func confirmUpload(mediaId: String, fileSize: Int64) async throws -> Vync_Media_ConfirmUploadResponse
}

// MARK: - Implementation

final class MediaRepositoryImpl: MediaRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func getUploadUrl(fileSize: Int64, contentType: String, sha256Hash: String) async throws -> Vync_Media_PresignedUrlResponse {
        SanchrLogger.media.info("Requesting upload URL for \(contentType), \(fileSize) bytes")

        var request = Vync_Media_GetUploadUrlRequest()
        request.fileSize = fileSize
        request.contentType = contentType
        request.sha256Hash = sha256Hash

        return try await grpcClient.mediaService.getUploadUrl(request)
    }

    func getDownloadUrl(mediaId: String) async throws -> Vync_Media_PresignedUrlResponse {
        SanchrLogger.media.info("Requesting download URL for media \(mediaId.prefix(8))...")

        var request = Vync_Media_GetDownloadUrlRequest()
        request.mediaID = mediaId

        return try await grpcClient.mediaService.getDownloadUrl(request)
    }

    func confirmUpload(mediaId: String, fileSize: Int64) async throws -> Vync_Media_ConfirmUploadResponse {
        SanchrLogger.media.info("Confirming upload for media \(mediaId.prefix(8))...")

        var request = Vync_Media_ConfirmUploadRequest()
        request.mediaID = mediaId
        request.fileSize = fileSize

        return try await grpcClient.mediaService.confirmUpload(request)
    }
}

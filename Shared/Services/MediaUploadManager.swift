import Foundation
import CryptoKit

/// Upload state for each media task.
enum MediaUploadState: Sendable {
    case queued
    case encrypting
    case uploading(progress: Double)
    case confirming
    case sendingMessage
    case completed
    case failed(error: String, retryCount: Int)
    case cancelled
}

/// A queued media upload task.
struct MediaUploadTask: Identifiable, Sendable {
    let id: String
    let conversationId: String
    let recipientId: String
    let localFileURL: URL
    let mimeType: String
    let caption: String?
    let replyToMessageId: String?
    var state: MediaUploadState
    var progress: Double
    var retryCount: Int
    let maxRetries: Int
    let createdAt: Date
    // Set after encryption
    var encryptedFileURL: URL?
    var encryptionMetadata: MediaEncryptionMetadata?
    // Set after upload
    var mediaId: String?
    var remoteURL: String?
    var thumbnailRemoteURL: String?
    // Optimistic message ID (for UI updates)
    var optimisticMessageId: String?

    init(
        conversationId: String,
        recipientId: String,
        localFileURL: URL,
        mimeType: String,
        caption: String? = nil,
        replyToMessageId: String? = nil
    ) {
        self.id = UUID().uuidString
        self.conversationId = conversationId
        self.recipientId = recipientId
        self.localFileURL = localFileURL
        self.mimeType = mimeType
        self.caption = caption
        self.replyToMessageId = replyToMessageId
        self.state = .queued
        self.progress = 0
        self.retryCount = 0
        self.maxRetries = 3
        self.createdAt = Date()
    }
}

/// Actor managing media upload queue with background URLSession support.
actor MediaUploadManager {
    private var tasks: [String: MediaUploadTask] = [:]
    private let mediaEncryption: MediaEncryptionProtocol
    private let grpcClient: GRPCClientProtocol

    /// Callback for UI progress updates (called on MainActor).
    nonisolated(unsafe) var onTaskUpdate: (@Sendable (MediaUploadTask) -> Void)?

    init(mediaEncryption: MediaEncryptionProtocol, grpcClient: GRPCClientProtocol) {
        self.mediaEncryption = mediaEncryption
        self.grpcClient = grpcClient
    }

    /// Queue a new upload task.
    func enqueue(_ task: MediaUploadTask) -> MediaUploadTask {
        var task = task
        task.state = .queued
        tasks[task.id] = task
        SanchrLogger.media.info("Queued upload task \(task.id.prefix(8))")
        return task
    }

    /// Execute the full upload pipeline for a task.
    func execute(_ taskId: String) async -> MediaUploadTask? {
        guard var task = tasks[taskId] else {
            SanchrLogger.media.error("Upload execute: task \(taskId.prefix(8)) not found")
            return nil
        }

        SanchrLogger.media.info("Upload execute: starting \(taskId.prefix(8)), file=\(task.localFileURL.lastPathComponent)")

        // Step 1: Encrypt
        task.state = .encrypting
        tasks[taskId] = task
        notifyUpdate(task)

        let tempDir = FileManager.default.temporaryDirectory
        let encryptedURL = tempDir.appendingPathComponent("\(task.id).enc")

        do {
            SanchrLogger.media.info("Upload \(taskId.prefix(8)): encrypting...")
            let metadata = try await mediaEncryption.encryptFile(
                at: task.localFileURL,
                to: encryptedURL
            )
            task.encryptedFileURL = encryptedURL
            task.encryptionMetadata = metadata
            SanchrLogger.media.info("Upload \(taskId.prefix(8)): encrypted, \(metadata.fileSize) bytes plaintext")
        } catch {
            SanchrLogger.media.error("Upload \(taskId.prefix(8)): encryption failed: \(error)")
            task.state = .failed(error: "Encryption failed: \(error.localizedDescription)", retryCount: task.retryCount)
            tasks[taskId] = task
            notifyUpdate(task)
            return task
        }

        // Step 2: Get presigned upload URL
        task.state = .uploading(progress: 0)
        tasks[taskId] = task
        notifyUpdate(task)

        do {
            let encryptedData = try Data(contentsOf: encryptedURL)
            SanchrLogger.media.info("Upload \(taskId.prefix(8)): encrypted blob \(encryptedData.count) bytes, getting presigned URL...")

            let hashHex = SHA256.hash(data: encryptedData).map { String(format: "%02x", $0) }.joined()

            var uploadReq = Vync_Media_GetUploadUrlRequest()
            uploadReq.fileSize = Int64(encryptedData.count)
            uploadReq.contentType = task.mimeType
            uploadReq.sha256Hash = hashHex
            uploadReq.purpose = .attachment

            let uploadResp = try await grpcClient.mediaService.getUploadUrl(uploadReq)
            task.mediaId = uploadResp.mediaID
            task.remoteURL = uploadResp.displayURL.isEmpty ? uploadResp.url : uploadResp.displayURL
            SanchrLogger.media.info("Upload \(taskId.prefix(8)): got presigned URL, mediaId=\(uploadResp.mediaID.prefix(8)), uploading to S3...")

            // Step 3: PUT to S3
            guard let putURL = URL(string: uploadResp.url) else {
                SanchrLogger.media.error("Upload \(taskId.prefix(8)): invalid presigned URL")
                throw AppError.mediaUploadFailed
            }

            var urlRequest = URLRequest(url: putURL)
            urlRequest.httpMethod = "PUT"
            urlRequest.setValue(task.mimeType, forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("\(encryptedData.count)", forHTTPHeaderField: "Content-Length")

            let (_, httpResponse) = try await URLSession.shared.upload(
                for: urlRequest,
                from: encryptedData
            )

            guard let response = httpResponse as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else {
                let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? -1
                SanchrLogger.media.error("Upload \(taskId.prefix(8)): S3 PUT failed, status=\(statusCode)")
                throw AppError.mediaUploadFailed
            }

            SanchrLogger.media.info("Upload \(taskId.prefix(8)): S3 PUT success, status=\(response.statusCode)")
            task.state = .uploading(progress: 1.0)
            task.progress = 1.0
            tasks[taskId] = task
            notifyUpdate(task)
        } catch {
            SanchrLogger.media.error("Upload \(taskId.prefix(8)): failed (attempt \(task.retryCount + 1)/\(task.maxRetries)): \(error)")
            task.retryCount += 1
            if task.retryCount < task.maxRetries {
                task.state = .failed(error: error.localizedDescription, retryCount: task.retryCount)
                tasks[taskId] = task
                notifyUpdate(task)
                let delay = pow(2.0, Double(task.retryCount)) * 2.0
                SanchrLogger.media.info("Upload \(taskId.prefix(8)): retrying in \(delay)s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return await execute(taskId)
            } else {
                SanchrLogger.media.error("Upload \(taskId.prefix(8)): giving up after \(task.maxRetries) retries")
                task.state = .failed(error: "Upload failed after \(task.maxRetries) retries", retryCount: task.retryCount)
                tasks[taskId] = task
                notifyUpdate(task)
                return task
            }
        }

        // Step 4: Confirm upload
        task.state = .confirming
        tasks[taskId] = task
        notifyUpdate(task)
        SanchrLogger.media.info("Upload \(taskId.prefix(8)): confirming upload...")

        do {
            var confirmReq = Vync_Media_ConfirmUploadRequest()
            confirmReq.mediaID = task.mediaId ?? ""
            confirmReq.fileSize = task.encryptionMetadata?.fileSize ?? 0
            _ = try await grpcClient.mediaService.confirmUpload(confirmReq)
            SanchrLogger.media.info("Upload \(taskId.prefix(8)): confirmed!")
        } catch {
            SanchrLogger.media.error("Upload \(taskId.prefix(8)): confirm failed: \(error)")
            task.state = .failed(error: "Confirm failed: \(error.localizedDescription)", retryCount: task.retryCount)
            tasks[taskId] = task
            notifyUpdate(task)
            return task
        }

        task.state = .sendingMessage
        tasks[taskId] = task
        notifyUpdate(task)
        SanchrLogger.media.info("Upload \(taskId.prefix(8)): ready to send message")

        // Cleanup encrypted temp file
        try? FileManager.default.removeItem(at: encryptedURL)

        return task
    }

    /// Cancel a task.
    func cancel(_ taskId: String) {
        guard var task = tasks[taskId] else { return }
        task.state = .cancelled
        tasks[taskId] = task
        notifyUpdate(task)
        // Cleanup temp files
        if let encURL = task.encryptedFileURL {
            try? FileManager.default.removeItem(at: encURL)
        }
        SanchrLogger.media.info("Cancelled upload task \(taskId.prefix(8))")
    }

    /// Mark task as completed.
    func markCompleted(_ taskId: String) {
        guard var task = tasks[taskId] else { return }
        task.state = .completed
        tasks[taskId] = task
        notifyUpdate(task)
    }

    /// Get current task state.
    func getTask(_ taskId: String) -> MediaUploadTask? {
        tasks[taskId]
    }

    private nonisolated func notifyUpdate(_ task: MediaUploadTask) {
        let callback = onTaskUpdate
        Task { @MainActor in
            callback?(task)
        }
    }
}

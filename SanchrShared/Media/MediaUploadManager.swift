import Foundation
import CryptoKit

/// Upload state for each media task.
public enum MediaUploadState: Sendable {
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
public struct MediaUploadTask: Identifiable, Sendable {
    public let id: String
    public let conversationId: String
    public let recipientId: String
    public let localFileURL: URL
    public let mimeType: String
    public let caption: String?
    public let replyToMessageId: String?
    public var state: MediaUploadState
    public var progress: Double
    public var retryCount: Int
    public let maxRetries: Int
    public let createdAt: Date
    // Set after encryption
    public var encryptedFileURL: URL?
    public var encryptedFileSize: Int64 = 0
    public var encryptionMetadata: MediaEncryptionMetadata?
    // Set after upload
    public var mediaId: String?
    public var remoteURL: String?
    public var thumbnailRemoteURL: String?
    // Optimistic message ID (for UI updates)
    public var optimisticMessageId: String?

    public init(
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
public actor MediaUploadManager {
    private var tasks: [String: MediaUploadTask] = [:]
    private let mediaEncryption: MediaEncryptionProtocol
    private let mediaKeyDerivation: MediaKeyDerivationProtocol
    private let mediaChainState: MediaChainState
    private let accessKeyStore: AccessKeyStoreProtocol
    private let grpcClient: GRPCClientProtocol

    /// Callback for UI progress updates (called on MainActor).
    public nonisolated(unsafe) var onTaskUpdate: (@Sendable (MediaUploadTask) -> Void)?

    public init(
        mediaEncryption: MediaEncryptionProtocol,
        mediaKeyDerivation: MediaKeyDerivationProtocol,
        mediaChainState: MediaChainState,
        accessKeyStore: AccessKeyStoreProtocol,
        grpcClient: GRPCClientProtocol
    ) {
        self.mediaEncryption = mediaEncryption
        self.mediaKeyDerivation = mediaKeyDerivation
        self.mediaChainState = mediaChainState
        self.accessKeyStore = accessKeyStore
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
            // 1. Read plaintext to compute file hash
            let plaintextData = try Data(contentsOf: task.localFileURL)
            let fileHash = Data(SHA256.hash(data: plaintextData))

            // 2. Get current chain key and derive MediaK
            //
            // The key belongs to this conversation, which is why the same file
            // sent to several conversations is uploaded several times. That
            // redundancy is required, not an oversight:
            //
            //   MediaK_n = HKDF(CK_n, file_hash, "media-v1")     (paper, D2)
            //
            // CK_n is *this* conversation's media chain key, erased on the
            // next line. One ciphertext has one key, so reusing an upload
            // elsewhere would mean that conversation's media key was never
            // derived from its own chain — and re-deriving means re-encrypting,
            // which means re-uploading anyway.
            //
            // It would also break the paper's core invariant. MediaK is
            // cross-domain (it transits the server inside a Signal-encrypted
            // message) but not persistent, because the chain advances past it.
            // Shared across conversations it would survive until the slowest
            // chain advanced — cross-domain *and* persistent, which is the
            // pair the design exists to keep apart. Compromising one
            // conversation would then expose media delivered in another.
            //
            // Compression is the part that can be shared, and is: see
            // `MessageSender.PreparedVideo`. Encryption and upload cannot be.
            let chainKey = mediaChainState.getOrInitChainKey(conversationId: task.conversationId)
            let mediaKey = mediaKeyDerivation.deriveMediaKey(chainKey: chainKey, fileHash: fileHash)

            // 3. Advance the chain (forward secrecy — old chain key is erased)
            mediaChainState.advanceChainKey(conversationId: task.conversationId)

            // 4. Encrypt file with derived MediaK
            SanchrLogger.media.info("Upload \(taskId.prefix(8)): encrypting with ratchet-derived key...")
            let metadata = try await mediaEncryption.encryptFile(
                at: task.localFileURL,
                to: encryptedURL,
                withKey: mediaKey
            )

            // 5. Store AccessK for future re-access
            let accessKey = mediaKeyDerivation.deriveAccessKey(
                mediaKey: mediaKey,
                mediaId: task.id,
                deviceSecret: mediaChainState.deviceSecretData
            )
            try await accessKeyStore.store(
                mediaId: task.id,
                accessKey: accessKey,
                conversationId: task.conversationId,
                kind: .messageMedia
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
            task.encryptedFileSize = Int64(encryptedData.count)
            tasks[taskId] = task
            SanchrLogger.media.info("Upload \(taskId.prefix(8)): encrypted blob \(encryptedData.count) bytes, getting presigned URL...")

            let hashHex = SHA256.hash(data: encryptedData).map { String(format: "%02x", $0) }.joined()

            var uploadReq = Sanchr_Media_GetUploadUrlRequest()
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
            var confirmReq = Sanchr_Media_ConfirmUploadRequest()
            confirmReq.mediaID = task.mediaId ?? ""
            confirmReq.fileSize = task.encryptedFileSize
            SanchrLogger.media.info("Upload \(taskId.prefix(8)): confirming with encryptedFileSize=\(task.encryptedFileSize)")
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

// MARK: - MediaUploading conformance

/// Adapts the richer `MediaUploadManager` pipeline (queue + multi-state
/// progress + retries) to the minimal `MediaUploading` surface that
/// `MessageSender` depends on. The adapter funnels a single file through
/// `enqueue` + `execute`, reports the terminal 0/1 progress points, and
/// surfaces the server identifiers in a `MediaUploadOutcome`.
///
/// NOTE: `MediaUploadManager.execute` currently only emits coarse state
/// transitions, not fine-grained byte progress, so `progress` is called
/// with 0.0 at the start and 1.0 on success. Fine-grained progress will be
/// wired up once the underlying `URLSession.upload` is migrated to the
/// delegate-based variant (tracked separately).
///
/// `execute(_:)` is already an `async` entry point on the actor, so no
/// `withCheckedThrowingContinuation` bridge is required — Swift concurrency
/// already guarantees a single resume. This eliminates the double-resume
/// hazard the prep plan called out for callback-based queues.
extension MediaUploadManager: MediaUploading {
    public func uploadMedia(
        localFileURL: URL,
        mimeType: String,
        conversationId: String,
        recipientId: String,
        progress: @Sendable (Double) -> Void
    ) async throws -> MediaUploadOutcome {
        progress(0.0)

        let queued = enqueue(
            MediaUploadTask(
                conversationId: conversationId,
                recipientId: recipientId,
                localFileURL: localFileURL,
                mimeType: mimeType
            )
        )

        guard let completed = await execute(queued.id) else {
            throw AppError.mediaUploadFailed
        }

        switch completed.state {
        case .sendingMessage, .completed:
            break
        case .failed(let reason, _):
            SanchrLogger.media.error("MediaUploading adapter: upload failed — \(reason)")
            throw AppError.mediaUploadFailed
        case .cancelled:
            throw AppError.mediaUploadFailed
        case .queued, .encrypting, .uploading, .confirming:
            // execute() should never return in a non-terminal state.
            throw AppError.mediaUploadFailed
        }

        guard
            let mediaId = completed.mediaId,
            let remoteURL = completed.remoteURL,
            let metadata = completed.encryptionMetadata
        else {
            SanchrLogger.media.error("MediaUploading adapter: completed task missing mediaId/remoteURL/encryptionMetadata")
            throw AppError.mediaUploadFailed
        }

        progress(1.0)

        return MediaUploadOutcome(
            mediaId: mediaId,
            remoteURL: remoteURL,
            thumbnailRemoteURL: completed.thumbnailRemoteURL,
            encryptedFileSize: completed.encryptedFileSize,
            plaintextFileSize: metadata.fileSize,
            encryptionKey: metadata.key,
            encryptionNonce: metadata.nonce,
            encryptionTag: metadata.tag,
            plaintextDigest: metadata.digest
        )
    }
}

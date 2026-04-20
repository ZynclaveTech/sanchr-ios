import Foundation
import SanchrShared

// MARK: - Send Pipeline
// Extracted from ChatDetailViewModel.swift on 2026-04-20 as part of god-file refactor.

extension ChatDetailViewModel {

    // MARK: - Send Message (E2EE)

    /// Sends the trimmed `inputText` via the shared `MessageSender` actor.
    ///
    /// `MessageSender` is the SOLE writer of outgoing message rows in the
    /// local DB — this view model only manages the in-memory transcript and
    /// the upload-progress dictionary the bubble UI reads. The optimistic
    /// in-memory row is keyed on a fresh UUID; on receipt we replace it with
    /// a `Message` built from the server-confirmed identifiers.
    func sendMessage(
        conversationId: String,
        sessionService: SessionService,
        messageSender: MessageSender
    ) async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Clear input immediately for responsive UI
        inputText = ""
        clearReply()
        isSending = true
        defer { isSending = false }

        // Optimistic UI: add message immediately with .sending status. The
        // id used here lives ONLY in the in-memory transcript — the DB row
        // MessageSender writes uses an independent local id, then is replaced
        // by the server-confirmed row inside the actor on success.
        let optimisticMessage = Message.textMessage(
            conversationId: conversationId,
            senderId: sessionService.currentUserId ?? "unknown",
            text: text,
            isOutgoing: true
        )
        messages.append(optimisticMessage)
        appendMessageToSections(optimisticMessage)

        do {
            let receipt = try await messageSender.sendText(text, to: conversationId)
            let serverTimestamp = Date(
                timeIntervalSince1970: TimeInterval(receipt.serverTimestampMs) / 1000.0
            )
            let confirmed = Message(
                id: receipt.messageId,
                conversationId: conversationId,
                senderId: optimisticMessage.senderId,
                timestamp: serverTimestamp,
                content: .text(text),
                status: .sent,
                isOutgoing: true,
                replyToMessageId: optimisticMessage.replyToMessageId
            )
            replaceMessage(id: optimisticMessage.id, with: confirmed)
            SanchrLogger.chat.info("Message sent successfully")
        } catch {
            updateMessage(id: optimisticMessage.id) { $0.status = .failed }
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Media Send

    /// Sends a media attachment (with optional caption) via the shared
    /// `MessageSender` actor. The actor owns the encrypt + upload + gRPC
    /// pipeline AND the local DB writes; this view model only manages the
    /// in-memory optimistic transcript row and the upload-progress dictionary.
    func sendMediaMessage(
        localFileURL: URL,
        mimeType: String,
        contentType: Message.MessageContent,
        conversationId: String,
        caption: String?,
        sessionService: SessionService,
        messageSender: MessageSender
    ) async {
        let senderId = sessionService.currentUserId ?? "unknown"

        // Build the optimistic in-memory row exactly like the legacy path —
        // including the caption applied to the underlying attachment so the
        // bubble renders the user's text under the thumbnail immediately.
        let optimisticContent: Message.MessageContent = {
            guard let caption else { return contentType }
            switch contentType {
            case .image(var a): a.caption = caption; return .image(a)
            case .video(var a): a.caption = caption; return .video(a)
            case .audio(var a): a.caption = caption; return .audio(a)
            case .document(var a): a.caption = caption; return .document(a)
            default: return contentType
            }
        }()

        let optimisticMessage = Message(
            id: UUID().uuidString,
            conversationId: conversationId,
            senderId: senderId,
            timestamp: Date(),
            content: optimisticContent,
            status: .sending,
            isOutgoing: true,
            replyToMessageId: replyingToMessage?.id
        )
        let optimisticId = optimisticMessage.id

        messages.append(optimisticMessage)
        appendMessageToSections(optimisticMessage)
        clearReply()

        // Pluck the underlying attachment so MessageSender has the structured
        // metadata (filename, voice-message flags, dimensions, etc.) it needs
        // to round-trip the wire format faithfully.
        let attachment: Message.MediaAttachment = {
            switch contentType {
            case .image(let a), .video(let a), .audio(let a), .document(let a):
                return a
            default:
                return Message.MediaAttachment(
                    url: localFileURL,
                    encryptionKey: Data(),
                    encryptionIV: Data(),
                    mimeType: mimeType,
                    sizeBytes: 0,
                    thumbnailURL: nil,
                    caption: caption
                )
            }
        }()

        uploads.update(id: optimisticId, progress: 0.0, status: "Encrypting...")

        do {
            let receipt = try await messageSender.sendMedia(
                attachment: attachment,
                caption: caption,
                to: conversationId
            ) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let status: String?
                    if fraction >= 1.0 {
                        status = "Sending..."
                    } else if fraction > 0 {
                        status = "Uploading..."
                    } else {
                        status = nil
                    }
                    self.uploads.update(id: optimisticId, progress: fraction, status: status)
                }
            }

            // Cache the sender's local file under the SERVER message id so
            // the bubble's `cachedMediaFilePath` lookup (which keys by
            // `messages` row id — the server id after confirm) actually
            // hits. Previously we keyed by `optimisticId`, so every sender
            // bubble missed the cache and fell back to the download
            // pipeline — or to a dead localFileURL if the picker temp was
            // already cleaned up by iOS.
            //
            // Cache location is the App Group's MediaCache (persistent)
            // rather than `.cachesDirectory` (which iOS evicts freely).
            let ext = mimeType.contains("png") ? "png"
                : mimeType.hasPrefix("video/") ? "mp4"
                : mimeType.hasPrefix("audio/") ? "m4a"
                : "jpg"
            let cacheDir = AppGroup.mediaCacheURL
                .appendingPathComponent("MediaMessages", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let cachedFile = cacheDir.appendingPathComponent("\(receipt.messageId).\(ext)")
            // Remove any previous copy (e.g., from a prior retry) before
            // linking — copyItem refuses to overwrite an existing file.
            try? FileManager.default.removeItem(at: cachedFile)
            try? FileManager.default.copyItem(at: localFileURL, to: cachedFile)

            let serverTimestamp = Date(
                timeIntervalSince1970: TimeInterval(receipt.serverTimestampMs) / 1000.0
            )
            // Reuse the optimistic content for the confirmed in-memory row.
            // The post-upload mediaId-URL swap is already persisted in the
            // DB row MessageSender wrote; the in-memory row keeps the local
            // file URL so the sender keeps seeing their own thumbnail
            // instantly without a network round-trip.
            let confirmed = Message(
                id: receipt.messageId,
                conversationId: conversationId,
                senderId: senderId,
                timestamp: serverTimestamp,
                content: optimisticContent,
                status: .sent,
                isOutgoing: true,
                replyToMessageId: optimisticMessage.replyToMessageId
            )
            replaceMessage(id: optimisticId, with: confirmed)
            uploads.clear(id: optimisticId)
            SanchrLogger.media.info("Media message sent: \(receipt.messageId)")
        } catch {
            updateMessage(id: optimisticId) { $0.status = .failed }
            // Keep the "Failed" label visible for the user even after the
            // progress value is gone — they need to see why the bubble shows
            // a retry affordance. A subsequent retry will call clear(id:).
            uploads.setStatus(id: optimisticId, status: "Failed")
            errorMessage = error.localizedDescription
            SanchrLogger.chat.error("Media message send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Forward Message

    /// Forwards `message` to `targetConversationId` by re-encrypting and
    /// sending its content as a new message in the target conversation.
    ///
    /// - Text: forwarded verbatim via `messageSender.sendText`.
    /// - Media: forwarded only if the attachment URL is a local file.
    ///   Remote-only attachments (not yet downloaded) are rejected with a
    ///   user-visible error — the user should download the media first.
    /// - Other content types (location, contact, system) are not forwardable.
    func forwardMessage(
        _ message: Message,
        toConversationId targetConversationId: String,
        sessionService: SessionService,
        messageSender: MessageSender
    ) async {
        let senderId = sessionService.currentUserId ?? "unknown"

        switch message.content {
        case .text(let text):
            let _ = Message(
                id: UUID().uuidString,
                conversationId: targetConversationId,
                senderId: senderId,
                timestamp: Date(),
                content: .text(text),
                status: .sending,
                isOutgoing: true
            )
            // Only append to transcript if we're already viewing the target conversation.
            // The check is intentionally omitted here — the target conversation's view
            // model will receive the server push and render it independently.
            do {
                let receipt = try await messageSender.sendText(text, to: targetConversationId)
                SanchrLogger.chat.info(
                    "Forwarded message \(message.id.prefix(8)) → \(receipt.messageId.prefix(8))")
            } catch {
                errorMessage = error.localizedDescription
                SanchrLogger.chat.error("Forward failed: \(error.localizedDescription)")
            }

        case .image(let a), .video(let a), .audio(let a), .document(let a):
            guard a.url.isFileURL else {
                errorMessage = "Download the media first to forward it."
                return
            }
            let optimisticId = UUID().uuidString
            uploads.update(id: optimisticId, progress: 0.0, status: "Forwarding...")
            do {
                let receipt = try await messageSender.sendMedia(
                    attachment: a,
                    caption: a.caption,
                    to: targetConversationId
                ) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.uploads.update(id: optimisticId, progress: fraction, status: nil)
                    }
                }
                uploads.clear(id: optimisticId)
                SanchrLogger.chat.info(
                    "Forwarded media \(message.id.prefix(8)) → \(receipt.messageId.prefix(8))")
            } catch {
                uploads.clear(id: optimisticId)
                errorMessage = error.localizedDescription
                SanchrLogger.chat.error("Forward media failed: \(error.localizedDescription)")
            }

        default:
            errorMessage = "This message type can't be forwarded."
        }
    }

    // MARK: - Attachment Intent Routing (Task 13)

    /// Bundle of dependencies + addressing info needed to fulfil an
    /// `AttachmentIntent`. The view layer constructs this once from the
    /// `DependencyContainer` and the active conversation/recipient and passes
    /// it into `send(intent:context:)`.
    struct AttachmentSendContext {
        let conversationId: String
        let recipientId: String
        let sessionService: SessionService
        let messageSender: MessageSender
        let vaultSharingCoordinator: VaultSharingCoordinating
    }

    /// Routes a user-issued `AttachmentIntent` from the attachment picker
    /// through the existing send pipeline. Each case is mapped to the most
    /// appropriate existing send path; cases without a structured payload yet
    /// fall back to a text message and are flagged with TODOs.
    @MainActor
    func send(intent: AttachmentIntent, context: AttachmentSendContext) async {
        switch intent {
        case .photoLibrary(let items):
            for item in items {
                await sendPickedMedia(item, context: context)
            }

        case .capturedMedia(let capture):
            await sendCapturedMedia(capture, context: context)

        case .file(let file):
            // Reuse the media pipeline; documents flow through the same
            // upload + encryption path with a non-image MIME type.
            await sendMediaMessage(
                localFileURL: file.url,
                mimeType: file.mimeType,
                contentType: .document({
                    var a = Message.MediaAttachment(
                        url: file.url,
                        encryptionKey: Data(),
                        encryptionIV: Data(),
                        mimeType: file.mimeType,
                        sizeBytes: file.sizeBytes,
                        thumbnailURL: nil,
                        caption: nil
                    )
                    a.filename = file.filename
                    return a
                }()),
                conversationId: context.conversationId,
                caption: nil,
                sessionService: context.sessionService,
                messageSender: context.messageSender
            )

        case .contact(let stripped):
            do {
                _ = try await context.messageSender.sendContact(
                    name: stripped.displayName,
                    phoneNumber: stripped.phoneNumbers.first ?? "",
                    to: context.conversationId
                )
            } catch {
                SanchrLogger.chat.error("Contact send failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }

        case .location(let payload):
            do {
                _ = try await context.messageSender.sendLocation(
                    latitude: payload.latitude,
                    longitude: payload.longitude,
                    to: context.conversationId
                )
            } catch {
                SanchrLogger.chat.error("Location send failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }

        case .vaultItem(let item):
            do {
                _ = try await context.vaultSharingCoordinator.reshareToCurrentChat(
                    item: item,
                    conversationId: context.conversationId
                )
                SanchrLogger.chat.info(
                    "vault reshare: sent \(item.id.prefix(8)) to \(context.conversationId.prefix(8))"
                )
            } catch {
                errorMessage = error.localizedDescription
                SanchrLogger.chat.error(
                    "vault reshare failed for \(item.id.prefix(8)): \(error.localizedDescription)"
                )
            }

        case .voice(let clip):
            let filename = "voice-\(Int(Date().timeIntervalSince1970 * 1000)).m4a"
            let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: clip.url.path)[.size] as? Int64) ?? 0
            var a = Message.MediaAttachment(
                url: clip.url,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: "audio/mp4",
                sizeBytes: sizeBytes,
                thumbnailURL: nil,
                caption: nil
            )
            a.filename = filename
            a.isVoiceMessage = true
            a.audioDurationMs = clip.durationMs
            a.audioWaveform = clip.waveform
            await sendMediaMessage(
                localFileURL: clip.url,
                mimeType: "audio/mp4",
                contentType: .audio(a),
                conversationId: context.conversationId,
                caption: nil,
                sessionService: context.sessionService,
                messageSender: context.messageSender
            )

        case .sticker(let pngData):
            // Write the PNG to a temp file and send through the image pipeline.
            // Stickers skip the caption screen — they send immediately.
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("sticker-\(UUID().uuidString).png")
            do {
                try pngData.write(to: tmpURL)
            } catch {
                SanchrLogger.chat.error("sticker: failed to write temp PNG: \(error.localizedDescription)")
                return
            }
            let attachment = Message.MediaAttachment(
                url: tmpURL,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: "image/png",
                sizeBytes: Int64(pngData.count),
                thumbnailURL: nil,
                caption: nil
            )
            await sendMediaMessage(
                localFileURL: tmpURL,
                mimeType: "image/png",
                contentType: .image(attachment),
                conversationId: context.conversationId,
                caption: nil,
                sessionService: context.sessionService,
                messageSender: context.messageSender
            )

        case .gif(let remoteURL):
            // Download the GIF from Tenor and send through the image pipeline.
            // GIFs skip the caption screen — they send immediately.
            do {
                let (data, _) = try await URLSession.shared.data(from: remoteURL)
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gif-\(UUID().uuidString).gif")
                try data.write(to: tmpURL)
                let attachment = Message.MediaAttachment(
                    url: tmpURL,
                    encryptionKey: Data(),
                    encryptionIV: Data(),
                    mimeType: "image/gif",
                    sizeBytes: Int64(data.count),
                    thumbnailURL: nil,
                    caption: nil
                )
                await sendMediaMessage(
                    localFileURL: tmpURL,
                    mimeType: "image/gif",
                    contentType: .image(attachment),
                    conversationId: context.conversationId,
                    caption: nil,
                    sessionService: context.sessionService,
                    messageSender: context.messageSender
                )
            } catch {
                SanchrLogger.chat.error("gif: download failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pure formatting helper for the contact text-fallback. Exposed for tests.
    ///
    /// Format: `[Contact] <name>` or `[Contact] <name>|<phone>`. Phone is
    /// appended when the stripped contact has at least one number so the
    /// receiver's bubble viewer can offer Message-on-Sanchr / Call / SMS
    /// / Save actions. Name-only payloads still parse for backward
    /// compatibility with older clients.
    static func contactFallbackText(_ stripped: StrippedContact) -> String {
        if let phone = stripped.phoneNumbers.first, !phone.isEmpty {
            return "[Contact] \(stripped.displayName)|\(phone)"
        }
        return "[Contact] \(stripped.displayName)"
    }

    /// Pure formatting helper for the location text-fallback. Exposed for tests.
    /// MUST NOT include any reverse-geocoded place data (privacy contract).
    static func locationFallbackText(_ payload: LocationPayload) -> String {
        "[Location] \(payload.latitude),\(payload.longitude)"
    }

    /// Stages a `CapturedMedia` blob to a temp file and returns the URL +
    /// derived MIME type. Exposed for tests so we can assert the
    /// pass-through-bytes contract without spinning up the full send pipeline.
    static func stageCapturedMediaForTesting(_ capture: CapturedMedia) throws -> (url: URL, mimeType: String) {
        let isVideo = capture.kind == .video
        let ext = isVideo ? "mp4" : "jpg"
        let mimeType = isVideo ? "video/mp4" : "image/jpeg"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
        try capture.data.write(to: tempURL)
        return (tempURL, mimeType)
    }

    private func sendPickedMedia(_ item: PickedMedia, context: AttachmentSendContext) async {
        let ext = item.mimeType.contains("png") ? "png"
            : item.mimeType.hasPrefix("video/") ? "mp4"
            : "jpg"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")

        // PhotosLibrarySource.loadVideo returns PickedMedia with an EMPTY
        // `data` and a populated `fileURL` pointing at an already-exported
        // local file; `loadPhoto` does the opposite (data present,
        // fileURL nil). Copy / write runs OFF the main actor — videos can
        // be large and blocking the main thread produces the "should not
        // be called on the main thread" warning plus an unresponsive UI
        // that looks like a crash.
        let itemData = item.data
        let itemFileURL = item.fileURL
        let stagingResult: Result<Int64, Error> = await Task.detached(priority: .userInitiated) {
            do {
                if let sourceURL = itemFileURL {
                    try? FileManager.default.removeItem(at: tempURL)
                    try FileManager.default.copyItem(at: sourceURL, to: tempURL)
                    let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                    let size = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
                    return .success(size)
                } else {
                    try itemData.write(to: tempURL)
                    return .success(Int64(itemData.count))
                }
            } catch {
                return .failure(error)
            }
        }.value

        let stagedSize: Int64
        switch stagingResult {
        case .success(let size):
            stagedSize = size
        case .failure(let error):
            SanchrLogger.chat.error("Failed to stage picked media: \(error.localizedDescription)")
            return
        }

        let attachment = Message.MediaAttachment(
            url: tempURL,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: item.mimeType,
            sizeBytes: stagedSize,
            thumbnailURL: nil,
            caption: nil
        )

        let content: Message.MessageContent
        switch item.kind {
        case .photo: content = .image(attachment)
        case .video: content = .video(attachment)
        }

        await sendMediaMessage(
            localFileURL: tempURL,
            mimeType: item.mimeType,
            contentType: content,
            conversationId: context.conversationId,
            caption: nil,
            sessionService: context.sessionService,
            messageSender: context.messageSender
        )
    }

    private func sendCapturedMedia(_ capture: CapturedMedia, context: AttachmentSendContext) async {
        let isVideo = capture.kind == .video
        let ext = isVideo ? "mp4" : "jpg"
        let mimeType = isVideo ? "video/mp4" : "image/jpeg"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            // Pass through bytes as-is; do not re-encode.
            try capture.data.write(to: tempURL)
        } catch {
            SanchrLogger.chat.error("Failed to stage captured media: \(error.localizedDescription)")
            return
        }

        let attachment = Message.MediaAttachment(
            url: tempURL,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: mimeType,
            sizeBytes: Int64(capture.data.count),
            thumbnailURL: nil,
            caption: nil
        )

        let content: Message.MessageContent = isVideo ? .video(attachment) : .image(attachment)

        await sendMediaMessage(
            localFileURL: tempURL,
            mimeType: mimeType,
            contentType: content,
            conversationId: context.conversationId,
            caption: nil,
            sessionService: context.sessionService,
            messageSender: context.messageSender
        )
    }
}

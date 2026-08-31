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
        // Re-entrancy guard. `isSending` was set and cleared here but read by
        // nothing, so it guarded nothing either — two sends could overlap and
        // the flag would just be set twice.
        guard !isSending else { return }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Read the reply BEFORE clearing it. This ran after `clearReply()`,
        // so the id was already nil by the time the message was built — the
        // reply banner was showing something the send then threw away.
        let replyToMessageId = replyingToMessage?.id

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
            isOutgoing: true,
            replyToMessageId: replyToMessageId
        )
        messages.append(optimisticMessage)
        appendMessageToSections(optimisticMessage)

        do {
            let receipt = try await messageSender.sendText(
                text,
                to: conversationId,
                replyToMessageId: replyToMessageId
            )
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
            // The bubble turns to Failed and carries its own retry, which is
            // both more precise and more actionable than a banner. Setting
            // errorMessage as well would report the same failure twice.
            updateMessage(id: optimisticMessage.id) { $0.status = .failed }
            SanchrLogger.chat.error("Send failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Media Send

    /// Sends a media attachment (with optional caption) via the shared
    /// `MessageSender` actor. The actor owns the encrypt + upload + gRPC
    /// pipeline AND the local DB writes; this view model only manages the
    /// in-memory optimistic transcript row and the upload-progress dictionary.
    /// Sends several attachments as one album, with an optimistic bubble.
    ///
    /// The view called `MessageSender.sendAlbum` directly, which writes its own
    /// database row but never touches `messages` — so nothing appeared until
    /// something else reloaded the transcript, which in practice meant leaving
    /// the chat and coming back. Every other send path inserts an optimistic
    /// row here first; this one now does too.
    @MainActor
    func sendAlbumMessage(
        attachments: [Message.MediaAttachment],
        caption: String?,
        conversationId: String,
        sessionService: SessionService,
        messageSender: MessageSender,
        mediaCache: MediaDownloadManager
    ) async {
        guard !attachments.isEmpty else { return }
        let senderId = sessionService.currentUserId ?? "unknown"

        // The optimistic row keeps the local file URLs so the sender sees their
        // own photos immediately, with no round trip.
        var localAttachments = attachments
        if let caption, localAttachments[0].caption == nil {
            localAttachments[0].caption = caption
        }
        // An album is as repliable as any other message; it simply never
        // carried the reference.
        let replyToMessageId = replyingToMessage?.id
        let optimisticContent = MessageSender.contentForAlbum(localAttachments)
        let optimisticMessage = Message(
            id: UUID().uuidString,
            conversationId: conversationId,
            senderId: senderId,
            timestamp: Date(),
            content: optimisticContent,
            status: .sending,
            isOutgoing: true,
            replyToMessageId: replyToMessageId
        )
        let optimisticId = optimisticMessage.id
        messages.append(optimisticMessage)
        appendMessageToSections(optimisticMessage)
        uploads.update(id: optimisticId, progress: 0.0, status: "Encrypting...")

        // Seed before the upload, not after it. The tiles render from these
        // for the whole time the upload runs, and the picker temp files they
        // would otherwise depend on are not ours to rely on.
        for (index, attachment) in localAttachments.enumerated() {
            await mediaCache.cacheLocalCopy(
                of: attachment.url,
                messageId: "\(optimisticId)#\(index)",
                mimeType: attachment.mimeType
            )
        }

        do {
            let receipt = try await messageSender.sendAlbum(
                attachments: attachments,
                caption: caption,
                to: conversationId,
                replyToMessageId: replyToMessageId,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.uploads.update(
                            id: optimisticId,
                            progress: fraction,
                            status: fraction >= 1.0 ? "Sending..." : "Uploading..."
                        )
                    }
                }
            )

            // Re-key the copies seeded before the upload started, rather than
            // copying the sources again — which by now may be gone.
            for (index, attachment) in attachments.enumerated() {
                await mediaCache.recache(
                    from: "\(optimisticId)#\(index)",
                    to: "\(receipt.messageId)#\(index)",
                    mimeType: attachment.mimeType
                )
            }

            let serverTimestamp = Date(
                timeIntervalSince1970: TimeInterval(receipt.serverTimestampMs) / 1000.0
            )
            replaceMessage(
                id: optimisticId,
                with: Message(
                    id: receipt.messageId,
                    conversationId: conversationId,
                    senderId: senderId,
                    timestamp: serverTimestamp,
                    content: optimisticContent,
                    status: .sent,
                    isOutgoing: true
                )
            )
            uploads.clear(id: optimisticId)
        } catch {
            SanchrLogger.chat.error("Album send failed: \(error.localizedDescription)")
            updateMessage(id: optimisticId) { $0.status = .failed }
            uploads.clear(id: optimisticId)
        }
    }

    func sendMediaMessage(
        localFileURL: URL,
        mimeType: String,
        contentType: Message.MessageContent,
        conversationId: String,
        caption: String?,
        sessionService: SessionService,
        messageSender: MessageSender,
        mediaCache: MediaDownloadManager
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
            case .image(let media), .video(let media), .audio(let media), .document(let media):
                // Sends still carry one attachment; an album will fan out here
                // once the send path uploads plural media.
                if let first = media.first { return first }
                fallthrough
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

        // Seeded before the upload so the bubble has something to render for
        // its duration; re-keyed to the server id once that id exists.
        await mediaCache.cacheLocalCopy(
            of: localFileURL,
            messageId: optimisticId,
            mimeType: mimeType
        )

        do {
            let receipt = try await messageSender.sendMedia(
                attachment: attachment,
                caption: caption,
                to: conversationId,
                replyToMessageId: optimisticMessage.replyToMessageId
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
            await mediaCache.recache(
                from: optimisticId,
                to: receipt.messageId,
                mimeType: mimeType
            )

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
            // Same as the text path: the bubble already says so.
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
    /// Forwards one message to one or more conversations.
    ///
    /// Takes every destination at once rather than being called in a loop.
    /// Sent one after another, each forward waited for the last to encrypt and
    /// upload before it started, so choosing three chats delivered three
    /// messages visibly apart. They go together now.
    /// - Parameter currentConversationId: the conversation on screen. A
    ///   forward into it has to appear in it, which a plain send does by
    ///   appending optimistically and a forward did not do at all — so
    ///   forwarding to the chat you were looking at showed nothing until the
    ///   transcript was reloaded.
    func forwardMessage(
        _ message: Message,
        toConversationIds targetConversationIds: [String],
        currentConversationId: String,
        sessionService: SessionService,
        messageSender: MessageSender,
        mediaResolver: ChatMediaResolving
    ) async {
        guard !targetConversationIds.isEmpty else { return }
        let senderId = sessionService.currentUserId ?? "unknown"

        switch message.content {
        case .text(let text):
            let echo = echoIntoCurrentConversation(
                content: .text(text),
                currentConversationId: currentConversationId,
                targets: targetConversationIds,
                senderId: senderId
            )
            let failures = await fanOut(targetConversationIds) { target in
                _ = try await messageSender.sendText(text, to: target)
            }
            settle(echo, allFailed: failures == targetConversationIds.count)

        case .image(let media), .video(let media), .audio(let media), .document(let media):
            guard let attachment = media.first else {
                errorMessage = "This message type can't be forwarded."
                return
            }

            // Resolved through the same path that draws the bubble.
            //
            // This used to require `attachment.url.isFileURL` and otherwise
            // told you to "download the media first". On a received message
            // that URL is remote whether or not the file is cached, so the
            // demand was made even for a photo you were looking at — and
            // there was nothing you could do to satisfy it.
            //
            // Resolved once, before the fan-out, so several destinations do
            // not each download the same file.
            let localAttachment: Message.MediaAttachment
            if attachment.url.isFileURL {
                localAttachment = attachment
            } else {
                let optimisticId = UUID().uuidString
                uploads.update(id: optimisticId, progress: 0, status: "Preparing…")
                defer { uploads.clear(id: optimisticId) }
                do {
                    let localURL = try await mediaResolver.decryptedURL(
                        forMessageId: message.id,
                        attachment: attachment
                    )
                    localAttachment = attachment.replacingURL(localURL)
                } catch {
                    errorMessage = "Couldn't prepare that media to forward."
                    SanchrLogger.chat.error(
                        "Forward: resolving media failed: \(error.localizedDescription)"
                    )
                    return
                }
            }

            // Compressed once for the whole fan-out. Each destination still
            // uploads its own copy — the upload is keyed to a conversation and
            // recipient, so sharing one would share key material between chats
            // and show the server a single media id in several of them — but
            // re-encoding the same clip once per destination bought nothing.
            let prepared = await messageSender.prepareVideoForReuse(localAttachment)
            defer { messageSender.discardPreparedVideo(prepared) }

            let echo = echoIntoCurrentConversation(
                content: message.content.replacingSoleAttachment(localAttachment),
                currentConversationId: currentConversationId,
                targets: targetConversationIds,
                senderId: senderId
            )
            let failures = await fanOut(targetConversationIds) { target in
                _ = try await messageSender.sendMedia(
                    attachment: localAttachment,
                    caption: localAttachment.caption,
                    to: target,
                    prepared: prepared,
                    progress: { _ in }
                )
            }
            settle(echo, allFailed: failures == targetConversationIds.count)

        default:
            errorMessage = "This message type can't be forwarded."
        }
    }

    /// Runs one send per destination concurrently and reports the shortfall.
    ///
    /// A forward that failed used to overwrite `errorMessage` with whichever
    /// failure finished last, so two failures out of three read like one.
    @discardableResult
    private func fanOut(
        _ targets: [String],
        _ send: @escaping @Sendable (String) async throws -> Void
    ) async -> Int {
        let failures = await withTaskGroup(of: Bool.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        try await send(target)
                        return false
                    } catch {
                        SanchrLogger.chat.error(
                            "Forward failed: \(error.localizedDescription)"
                        )
                        return true
                    }
                }
            }
            var failed = 0
            for await didFail in group where didFail { failed += 1 }
            return failed
        }

        guard failures > 0 else { return 0 }
        errorMessage = failures == targets.count
            ? "Couldn't forward that message."
            : "Couldn't forward to \(failures) of \(targets.count) chats."
        return failures
    }

    /// Shows a forward into the conversation on screen, straight away.
    ///
    /// The real row is written by `MessageSender` against the target
    /// conversation, which is correct but invisible: this transcript is
    /// already loaded and does not re-read the database. A plain send appends
    /// optimistically for the same reason.
    private func echoIntoCurrentConversation(
        content: Message.MessageContent,
        currentConversationId: String,
        targets: [String],
        senderId: String
    ) -> String? {
        guard targets.contains(currentConversationId) else { return nil }
        let echo = Message(
            id: UUID().uuidString,
            conversationId: currentConversationId,
            senderId: senderId,
            timestamp: Date(),
            content: content,
            status: .sending,
            isOutgoing: true
        )
        appendMessageChronologically(echo)
        return echo.id
    }

    /// Marks the echo sent or failed once every destination has answered.
    ///
    /// It keeps its own id rather than being replaced by the server-confirmed
    /// row — the confirmed row is already in the database and arrives on the
    /// next load, and swapping ids here would show the message twice until
    /// then.
    private func settle(_ echoId: String?, allFailed: Bool) {
        guard let echoId else { return }
        updateMessage(id: echoId) { $0.status = allFailed ? .failed : .sent }
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
        /// Seeds the sender's own media so their bubbles render from disk
        /// rather than asking to download a file they already have.
        let mediaCache: MediaDownloadManager
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
                    return .init(a)
                }()),
                conversationId: context.conversationId,
                caption: nil,
                sessionService: context.sessionService,
                messageSender: context.messageSender,
                mediaCache: context.mediaCache
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
                contentType: .audio(.init(a)),
                conversationId: context.conversationId,
                caption: nil,
                sessionService: context.sessionService,
                messageSender: context.messageSender,
                mediaCache: context.mediaCache
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
                contentType: .image(.init(attachment)),
                conversationId: context.conversationId,
                caption: nil,
                sessionService: context.sessionService,
                messageSender: context.messageSender,
                mediaCache: context.mediaCache
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
                    contentType: .image(.init(attachment)),
                    conversationId: context.conversationId,
                    caption: nil,
                    sessionService: context.sessionService,
                    messageSender: context.messageSender,
                    mediaCache: context.mediaCache
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
        case .photo: content = .image(.init(attachment))
        case .video: content = .video(.init(attachment))
        }

        await sendMediaMessage(
            localFileURL: tempURL,
            mimeType: item.mimeType,
            contentType: content,
            conversationId: context.conversationId,
            caption: nil,
            sessionService: context.sessionService,
            messageSender: context.messageSender,
            mediaCache: context.mediaCache
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

        let content: Message.MessageContent = isVideo ? .video(.init(attachment)) : .image(.init(attachment))

        await sendMediaMessage(
            localFileURL: tempURL,
            mimeType: mimeType,
            contentType: content,
            conversationId: context.conversationId,
            caption: nil,
            sessionService: context.sessionService,
            messageSender: context.messageSender,
            mediaCache: context.mediaCache
        )
    }
}

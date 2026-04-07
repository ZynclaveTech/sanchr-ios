import Foundation
import SanchrShared

// MARK: - OneShotAuthRetrying

/// Minimal `AuthRetrying` implementation for the share extension.
///
/// The share extension can't refresh access tokens on its own (token refresh
/// requires the full `SessionService` machinery that lives in the main app).
/// Instead we run the body exactly once and let any UNAUTHENTICATED error
/// surface as a per-recipient failure. Users will re-open the main app to
/// refresh and retry from there.
struct OneShotAuthRetrying: AuthRetrying {
    func withAuthRetry<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await body()
    }
}

// MARK: - KeychainSnapshotCurrentUserProvider

/// Minimal `CurrentUserProviding` implementation that reads the currently
/// signed-in user from the `SessionSnapshot` that the main app persists to
/// the shared Keychain on every successful auth. If the snapshot is missing
/// or the keychain read fails, the extension surfaces a session-expired
/// error at send time.
struct KeychainSnapshotCurrentUserProvider: CurrentUserProviding {
    let secureStorage: SecureStorageProtocol

    var currentUserId: String? {
        get async {
            (try? secureStorage.readSessionSnapshot())?.userId
        }
    }
}

// MARK: - ShareSendCoordinator

/// Drives the share-extension send pipeline for one `SharePayload` across
/// one or more recipients. Conforms to `ShareSendDriving` so the UI can stay
/// ignorant of the concrete type and still receive per-recipient progress.
///
/// The coordinator builds its own, self-contained dependency stack on
/// `send(...)` — the share extension has no `DependencyContainer` and can't
/// share one with the main app because it runs in a separate process. Every
/// dependency is built from extension-safe primitives (shared Keychain,
/// shared App Group database, extension-API-only SanchrShared framework).
///
/// Recipients are fanned out in a structured task group so failures on one
/// recipient don't block the others, and the whole operation honours
/// `Task.isCancelled` for graceful teardown when the user dismisses the
/// share sheet mid-send.
final actor ShareSendCoordinator: ShareSendDriving {

    init() {}

    func send(
        payload: SharePayload,
        caption: String?,
        recipients: [ShareChatSummary],
        progress: @Sendable @escaping (String, ShareRecipientState, Double) -> Void
    ) async {
        // Build the dependency stack once for this entire batch.
        let deps: Dependencies
        do {
            deps = try Self.makeDependencies()
        } catch {
            SanchrLogger.chat.error("ShareSendCoordinator: bootstrap failed: \(error.localizedDescription)")
            // Every recipient fails with the bootstrap reason.
            let reason = Self.friendlyBootstrapError(error)
            for recipient in recipients {
                progress(recipient.id, .failure(reason), 0)
            }
            return
        }

        // Normalise the payload into an ordered list of "send units" so that
        // a `.multi` payload is sent as one text/one media per child, in the
        // order the user picked them.
        let units = Self.flatten(payload: payload, caption: caption)

        let total = max(recipients.count, 1)
        let completedCountBox = CompletedCount()

        await withTaskGroup(of: Void.self) { group in
            for recipient in recipients {
                group.addTask { [units, caption] in
                    if Task.isCancelled {
                        progress(recipient.id, .failure("Cancelled"), 0)
                        return
                    }
                    progress(recipient.id, .sending, 0)
                    let finalState: ShareRecipientState
                    do {
                        try await Self.dispatch(
                            units: units,
                            caption: caption,
                            recipient: recipient,
                            sender: deps.messageSender
                        )
                        finalState = .success
                    } catch {
                        SanchrLogger.chat.error(
                            "ShareSendCoordinator: send to \(recipient.id.prefix(8)) failed: \(error.localizedDescription)"
                        )
                        finalState = .failure(Self.friendlySendError(error))
                    }
                    let completed = await completedCountBox.increment()
                    progress(recipient.id, finalState, Double(completed) / Double(total))
                }
            }
            await group.waitForAll()
        }
    }

    // MARK: - Dependency bootstrap

    private struct Dependencies {
        let messageSender: MessageSender
    }

    private static func makeDependencies() throws -> Dependencies {
        let keychain = KeychainService(accessGroup: AppGroup.keychainAccessGroup)
        let secureStorage = SecureStorage(keychain: keychain)

        guard let mediaSecret = try secureStorage.readMediaAccessSecret() else {
            throw ShareSendBootstrapError.missingMediaAccessSecret
        }
        let mediaChainState = MediaChainState(deviceSecret: mediaSecret)

        let db = try LocalDatabase.openForExtension()

        let configuration = AppConfiguration.current
        let authFactory = AuthInterceptorFactory(
            secureStorage: secureStorage,
            onUnauthenticated: {}
        )
        let grpcClient = SanchrGRPCClient(
            configuration: configuration,
            authInterceptors: authFactory
        )

        // Signal protocol stack — pinned to the user currently signed in on
        // this device. `SanchrSignalStore` reads keys from the shared
        // Keychain access group, so the main app and the share extension
        // share one identity.
        let userId = (try secureStorage.readSessionSnapshot())?.userId ?? "pending"
        let signalStore = SanchrSignalStore(userId: userId, keychainService: keychain)
        let keyManager = SignalKeyManager(store: signalStore, keyService: grpcClient.keyService)
        let sessionManager = SignalSessionManager(store: signalStore, keyManager: keyManager)

        let accessKeyStore = AccessKeyStore(localDatabase: db)
        let mediaEncryption = MediaEncryptor()
        let mediaKeyDerivation = MediaKeyDerivation()

        let uploader = MediaUploadManager(
            mediaEncryption: mediaEncryption,
            mediaKeyDerivation: mediaKeyDerivation,
            mediaChainState: mediaChainState,
            accessKeyStore: accessKeyStore,
            grpcClient: grpcClient
        )

        let encryptedSender = DefaultEncryptedMessageSendingClient(
            grpcClient: grpcClient,
            signalManager: sessionManager,
            authRetrier: OneShotAuthRetrying()
        )

        let lock = FileCoordinatorLock()
        let currentUser = KeychainSnapshotCurrentUserProvider(secureStorage: secureStorage)

        let sender = MessageSender(
            db: db,
            uploader: uploader,
            encryptedSender: encryptedSender,
            coordinator: lock,
            currentUser: currentUser
        )

        return Dependencies(messageSender: sender)
    }

    // MARK: - Dispatch

    /// A single send unit extracted from a possibly-compound `SharePayload`.
    /// The caption rides on the FIRST unit only so multi-attachment shares
    /// don't double-post the caption.
    fileprivate struct SendUnit: Sendable {
        enum Kind: Sendable {
            case text(String)
            case media(Message.MediaAttachment)
        }
        let kind: Kind
        let carriesCaption: Bool
    }

    private static func flatten(payload: SharePayload, caption: String?) -> [SendUnit] {
        let parts: [SharePayload]
        switch payload {
        case .multi(let children): parts = children
        default: parts = [payload]
        }

        var units: [SendUnit] = []
        var captionAssigned = false
        for part in parts {
            if let unit = makeUnit(from: part, caption: captionAssigned ? nil : caption) {
                units.append(unit)
                if !captionAssigned { captionAssigned = true }
            }
        }
        return units
    }

    private static func makeUnit(from payload: SharePayload, caption: String?) -> SendUnit? {
        switch payload {
        case .text(let text):
            let body = [text, caption].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n\n")
            guard !body.isEmpty else { return nil }
            return SendUnit(kind: .text(body), carriesCaption: caption != nil)

        case .url(let url):
            let urlString = url.absoluteString
            let body = [urlString, caption].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n\n")
            return SendUnit(kind: .text(body), carriesCaption: caption != nil)

        case .image(let fileURL, let size):
            let mime = mimeType(for: fileURL, fallback: "image/jpeg")
            let attachment = Message.MediaAttachment(
                url: fileURL,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: mime,
                sizeBytes: size,
                caption: caption,
                filename: fileURL.lastPathComponent
            )
            return SendUnit(kind: .media(attachment), carriesCaption: caption != nil)

        case .video(let fileURL, let size, let duration):
            let mime = mimeType(for: fileURL, fallback: "video/mp4")
            let attachment = Message.MediaAttachment(
                url: fileURL,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: mime,
                sizeBytes: size,
                caption: caption,
                durationSeconds: duration,
                filename: fileURL.lastPathComponent
            )
            return SendUnit(kind: .media(attachment), carriesCaption: caption != nil)

        case .audio(let fileURL, let size, let duration):
            let mime = mimeType(for: fileURL, fallback: "audio/m4a")
            let attachment = Message.MediaAttachment(
                url: fileURL,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: mime,
                sizeBytes: size,
                caption: caption,
                durationSeconds: duration,
                filename: fileURL.lastPathComponent
            )
            return SendUnit(kind: .media(attachment), carriesCaption: caption != nil)

        case .file(let fileURL, let size, let filename):
            let mime = mimeType(for: fileURL, fallback: "application/octet-stream")
            let attachment = Message.MediaAttachment(
                url: fileURL,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: mime,
                sizeBytes: size,
                caption: caption,
                filename: filename
            )
            return SendUnit(kind: .media(attachment), carriesCaption: caption != nil)

        case .multi:
            // Callers should flatten before calling this, but be defensive.
            return nil
        }
    }

    private static func dispatch(
        units: [SendUnit],
        caption: String?,
        recipient: ShareChatSummary,
        sender: MessageSender
    ) async throws {
        for unit in units {
            if Task.isCancelled { throw CancellationError() }
            switch unit.kind {
            case .text(let body):
                _ = try await sender.sendText(body, to: recipient.id)
            case .media(let attachment):
                _ = try await sender.sendMedia(
                    attachment: attachment,
                    caption: attachment.caption,
                    to: recipient.id,
                    progress: { _ in }
                )
            }
        }
    }

    // MARK: - Error mapping

    private static func friendlyBootstrapError(_ error: Error) -> String {
        if let bootstrap = error as? ShareSendBootstrapError {
            switch bootstrap {
            case .missingMediaAccessSecret:
                return "Open Sanchr once to finish setup, then try sharing again."
            }
        }
        if let appError = error as? AppError {
            return appError.localizedDescription
        }
        return error.localizedDescription
    }

    private static func friendlySendError(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled" }
        if let appError = error as? AppError {
            return appError.localizedDescription
        }
        return error.localizedDescription
    }

    // MARK: - MIME helpers

    private static func mimeType(for url: URL, fallback: String) -> String {
        // Lightweight best-effort mapping — the loader already validated the
        // payload type so we only need coarse bucketing here.
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4a", "aac": return "audio/m4a"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "pdf": return "application/pdf"
        default: return fallback
        }
    }
}

// MARK: - Helpers

private enum ShareSendBootstrapError: Error {
    case missingMediaAccessSecret
}

/// Thread-safe completion counter used by the structured task group to
/// drive the overall progress bar. An actor keeps the increments
/// race-free without leaking isolation into the progress closure.
private actor CompletedCount {
    private var value: Int = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

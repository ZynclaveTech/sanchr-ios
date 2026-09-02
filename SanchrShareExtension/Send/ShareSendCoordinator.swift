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
        // order the user picked them. The actual fan-out + concurrency lives
        // in `ShareSendDispatcher` (in SanchrShared) so it's testable from
        // the main-app unit-test target without `@testable import`-ing this
        // app-extension binary.
        let units = Self.flatten(payload: payload, caption: caption)
        // The dispatcher treats no units as an immediate success for every
        // recipient. A share whose only part flattened to nothing — empty
        // text, say — must not come back as "Sent".
        guard !units.isEmpty else {
            SanchrLogger.chat.error("ShareSendCoordinator: payload produced no send units")
            payload.removeFiles()
            for recipient in recipients {
                progress(recipient.id, .failure("Nothing to share."), 1)
            }
            return
        }
        let dispatcher = ShareSendDispatcher(sender: deps.messageSender)
        let recipientIds = recipients.map(\.id)

        let anySent = SentFlag()
        await dispatcher.send(units: units, to: recipientIds) { recipientId, outcome, overall in
            let mapped = Self.mapOutcome(outcome)
            if case .failure(let reason) = mapped {
                SanchrLogger.chat.error(
                    "ShareSendCoordinator: send to \(recipientId.prefix(8)) failed: \(reason)"
                )
            }
            if case .success = mapped { anySent.set() }
            progress(recipientId, mapped, overall)
        }
        // The copies in the App Group cache are the sent messages' local
        // media. If nothing went out they are just leftovers — and until
        // this, nothing ever deleted them.
        if !anySent.value {
            payload.removeFiles()
        }
    }

    private final class SentFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    private static func mapOutcome(_ outcome: ShareRecipientOutcome) -> ShareRecipientState {
        switch outcome {
        case .sending: return .sending
        case .success: return .success
        case .cancelled: return .failure("Cancelled")
        case .failure(let reason): return .failure(reason)
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
            currentUser: currentUser,
            vaultPolicyResolver: NoopVaultPolicyResolver(),
            networkMonitor: NetworkMonitor()
        )

        return Dependencies(messageSender: sender)
    }

    // MARK: - Payload flattening

    /// Flatten a possibly-compound `SharePayload` into the ordered list of
    /// `ShareSendUnit`s the dispatcher consumes. The caption rides on the
    /// FIRST unit only so multi-attachment shares don't double-post it.
    private static func flatten(payload: SharePayload, caption: String?) -> [ShareSendUnit] {
        let parts: [SharePayload]
        switch payload {
        case .multi(let children): parts = children
        default: parts = [payload]
        }

        var units: [ShareSendUnit] = []
        var captionAssigned = false
        for part in parts {
            let captionForPart = captionAssigned ? nil : caption
            if let unit = makeUnit(from: part, caption: captionForPart) {
                units.append(unit)
                if captionForPart != nil { captionAssigned = true }
            }
        }
        return units
    }

    private static func makeUnit(from payload: SharePayload, caption: String?) -> ShareSendUnit? {
        switch payload {
        case .text(let text):
            let body = [text, caption].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n\n")
            guard !body.isEmpty else { return nil }
            return .text(body)

        case .url(let url):
            let urlString = url.absoluteString
            let body = [urlString, caption].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n\n")
            return .text(body)

        case .image(let fileURL, let size):
            return .media(Message.MediaAttachment(
                url: fileURL,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: mimeType(for: fileURL, fallback: "image/jpeg"),
                sizeBytes: size,
                caption: caption,
                filename: fileURL.lastPathComponent
            ))

        case .video(let fileURL, let size, let duration):
            return .media(Message.MediaAttachment(
                url: fileURL,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: mimeType(for: fileURL, fallback: "video/mp4"),
                sizeBytes: size,
                caption: caption,
                durationSeconds: duration,
                filename: fileURL.lastPathComponent
            ))

        case .audio(let fileURL, let size, let duration):
            return .media(Message.MediaAttachment(
                url: fileURL,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: mimeType(for: fileURL, fallback: "audio/m4a"),
                sizeBytes: size,
                caption: caption,
                durationSeconds: duration,
                filename: fileURL.lastPathComponent
            ))

        case .file(let fileURL, let size, let filename):
            return .media(Message.MediaAttachment(
                url: fileURL,
                encryptionKey: Data(),
                encryptionIV: Data(),
                mimeType: mimeType(for: fileURL, fallback: "application/octet-stream"),
                sizeBytes: size,
                caption: caption,
                filename: filename
            ))

        case .multi:
            // Callers must flatten before calling this; be defensive.
            return nil
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

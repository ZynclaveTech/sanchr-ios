import Foundation
import GRPC

// MARK: - EncryptedMessageSendResult

/// Authoritative identifiers returned by the server after a successful
/// encrypted-envelope send. Carried back to `MessageSender` (and ultimately
/// `ChatDetailViewModel` / `ShareSendCoordinator`) so optimistic UI state can
/// be reconciled with the server-assigned message id and timestamp.
public struct EncryptedMessageSendResult: Sendable, Equatable {
    public let messageId: String
    public let serverTimestampMs: Int64

    public init(messageId: String, serverTimestampMs: Int64) {
        self.messageId = messageId
        self.serverTimestampMs = serverTimestampMs
    }
}

// MARK: - AuthRetrying

/// Narrow protocol that lets SanchrShared types perform a gRPC call inside an
/// auth-retry envelope without depending on the main-app `SessionService`.
///
/// Concrete implementations are expected to refresh the access token on
/// `UNAUTHENTICATED` and retry the body exactly once. The body MUST be safe
/// to invoke twice.
public protocol AuthRetrying: Sendable {
    func withAuthRetry<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T
}

// MARK: - EncryptedMessageSendingClient

/// Narrow seam used by `MessageSender` (and any other extension-safe sender)
/// to dispatch a single E2EE message via gRPC. Implementations are responsible
/// for:
///
/// 1. Encrypting `plaintext` for every device of every recipient via
///    `SignalProtocolManagerProtocol.encryptForAllDevices`.
/// 2. Wrapping the gRPC `sendMessage` call in an `AuthRetrying` envelope so
///    expired access tokens get refreshed transparently.
/// 3. Translating the proto response into an `EncryptedMessageSendResult`.
///
/// Deliberately tiny: no UI state, no optimistic-message bookkeeping, no
/// per-conversation queueing. Those concerns live in `MessageSender`.
public protocol EncryptedMessageSendingClient: Sendable {
    func sendEncryptedMessage(
        plaintext: Data,
        contentType: String,
        conversationId: String,
        recipientIds: [String],
        expiresAfterSecs: Int64
    ) async throws -> EncryptedMessageSendResult
}

public extension EncryptedMessageSendingClient {
    /// Convenience overload for the common single-recipient, no-TTL case.
    func sendEncryptedMessage(
        plaintext: Data,
        contentType: String,
        conversationId: String,
        recipientId: String
    ) async throws -> EncryptedMessageSendResult {
        try await sendEncryptedMessage(
            plaintext: plaintext,
            contentType: contentType,
            conversationId: conversationId,
            recipientIds: [recipientId],
            expiresAfterSecs: 0
        )
    }
}

// MARK: - DefaultEncryptedMessageSendingClient

/// Default extension-safe implementation. Mirrors the core logic of
/// `ChatDataSource.sendEncryptedMessage` + `ChatDataSource.sendMessage` so
/// that the share extension can perform an encrypted send without importing
/// any main-app types.
///
/// NOTE: The main-app `ChatDataSource.sendEncryptedMessage` path remains in
/// place until the rest of T16 lands and `ChatDetailViewModel` is rewired.
public final class DefaultEncryptedMessageSendingClient: EncryptedMessageSendingClient {

    private let grpcClient: GRPCClientProtocol
    private let signalManager: SignalProtocolManagerProtocol
    private let authRetrier: AuthRetrying

    public init(
        grpcClient: GRPCClientProtocol,
        signalManager: SignalProtocolManagerProtocol,
        authRetrier: AuthRetrying
    ) {
        self.grpcClient = grpcClient
        self.signalManager = signalManager
        self.authRetrier = authRetrier
    }

    public func sendEncryptedMessage(
        plaintext: Data,
        contentType: String,
        conversationId: String,
        recipientIds: [String],
        expiresAfterSecs: Int64
    ) async throws -> EncryptedMessageSendResult {
        // 1. Per-device encryption fan-out (matches ChatDataSource).
        var allDeviceMessages: [Vync_Messaging_DeviceMessage] = []
        for recipientId in recipientIds {
            let deviceMessages = try await signalManager.encryptForAllDevices(
                plaintext: plaintext,
                recipientId: recipientId
            )
            allDeviceMessages.append(contentsOf: deviceMessages)
        }

        // 2. Build the wire request. `let` so it can be captured by the
        //    `@Sendable` closure passed to `withAuthRetry`.
        let request: Vync_Messaging_SendMessageRequest = {
            var r = Vync_Messaging_SendMessageRequest()
            r.conversationID = conversationId
            r.deviceMessages = allDeviceMessages
            r.contentType = contentType
            r.expiresAfterSecs = expiresAfterSecs
            return r
        }()

        // 3. Dispatch under the auth-retry envelope so expired access tokens
        //    are refreshed transparently. The body is idempotent from the
        //    client's perspective: a server that has already accepted the
        //    request will return the same id on retry.
        let messagingClient = grpcClient.messagingService
        let response = try await authRetrier.withAuthRetry {
            try await messagingClient.sendMessage(request)
        }

        return EncryptedMessageSendResult(
            messageId: response.messageID,
            serverTimestampMs: response.serverTimestamp
        )
    }
}

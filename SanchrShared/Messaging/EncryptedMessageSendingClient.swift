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

// MARK: - SealedMessageSendResult

/// Result of a sealed sender send. The server returns only a timestamp
/// (no messageId) because the server cannot attribute the message to a sender.
public struct SealedMessageSendResult: Sendable, Equatable {
    public let serverTimestampMs: Int64

    public init(serverTimestampMs: Int64) {
        self.serverTimestampMs = serverTimestampMs
    }
}

// MARK: - SealedMessageSendingClient

/// Narrow seam for sending a message through the sealed sender pipeline.
///
/// The sealed sender path:
/// 1. Wraps plaintext in an `InnerPayload` (conversation context + content).
/// 2. Signal-encrypts the inner payload per recipient device.
/// 3. Builds `SealedDeviceMessage` protos (recipient_id, device_id, sealed_envelope).
/// 4. Builds self-sync envelopes for the sender's own other devices.
/// 5. Acquires a delivery token (not JWT) and dispatches via `SendSealedMessage`.
///
/// Like `EncryptedMessageSendingClient`, this protocol has no UI or DB concerns.
public protocol SealedMessageSendingClient: Sendable {
    func sendSealedMessage(
        plaintext: Data,
        contentType: String,
        conversationId: String,
        recipientIds: [String],
        senderId: String
    ) async throws -> SealedMessageSendResult
}

// MARK: - DefaultSealedMessageSendingClient

/// Production sealed sender send client.
///
/// Encrypts per-device, wraps in `InnerPayload`, acquires a delivery token,
/// and dispatches via the unauthenticated `SendSealedMessage` RPC (no JWT).
public final class DefaultSealedMessageSendingClient: SealedMessageSendingClient {

    private let grpcClient: GRPCClientProtocol
    private let signalManager: SignalProtocolManagerProtocol
    private let sealedSenderManager: SealedSenderManagerProtocol

    public init(
        grpcClient: GRPCClientProtocol,
        signalManager: SignalProtocolManagerProtocol,
        sealedSenderManager: SealedSenderManagerProtocol
    ) {
        self.grpcClient = grpcClient
        self.signalManager = signalManager
        self.sealedSenderManager = sealedSenderManager
    }

    public func sendSealedMessage(
        plaintext: Data,
        contentType: String,
        conversationId: String,
        recipientIds: [String],
        senderId: String
    ) async throws -> SealedMessageSendResult {
        // 1. Build the InnerPayload (peer copy: isSync = false).
        let innerPayloadData = try sealedSenderManager.encodeInnerPayload(
            conversationId: conversationId,
            contentType: contentType,
            content: plaintext,
            isSync: false
        )

        // 2. Fetch sender certificate (used for sender identity binding; kept
        //    in scope so it's available for future libsignal sealed sender
        //    integration but not embedded in the envelope today since we're
        //    using Signal-encrypt + delivery token auth).
        _ = try await sealedSenderManager.getSenderCertificate()

        // 3. Per-device encryption for each peer recipient.
        var sealedDeviceMessages: [Vync_Messaging_SealedDeviceMessage] = []
        for recipientId in recipientIds {
            let deviceMessages = try await signalManager.encryptForAllDevices(
                plaintext: innerPayloadData,
                recipientId: recipientId
            )
            for dm in deviceMessages {
                var sealed = Vync_Messaging_SealedDeviceMessage()
                sealed.recipientID = dm.recipientID
                sealed.deviceID = dm.deviceID
                sealed.sealedEnvelope = dm.ciphertext
                sealedDeviceMessages.append(sealed)
            }
        }

        // 4. Self-sync: build InnerPayload with isSync=true and encrypt for
        //    the sender's own other devices so multi-device stays in sync.
        let syncPayloadData = try sealedSenderManager.encodeInnerPayload(
            conversationId: conversationId,
            contentType: contentType,
            content: plaintext,
            isSync: true
        )
        do {
            let selfDeviceMessages = try await signalManager.encryptForAllDevices(
                plaintext: syncPayloadData,
                recipientId: senderId
            )
            for dm in selfDeviceMessages {
                var sealed = Vync_Messaging_SealedDeviceMessage()
                sealed.recipientID = dm.recipientID
                sealed.deviceID = dm.deviceID
                sealed.sealedEnvelope = dm.ciphertext
                sealedDeviceMessages.append(sealed)
            }
        } catch {
            // Self-sync failure is non-fatal: the message still reaches
            // the peer. Log and continue so the send is not blocked by a
            // missing self-device key bundle (e.g. single-device user).
            SanchrLogger.crypto.warning(
                "Sealed sender self-sync encrypt failed (non-fatal): \(error.localizedDescription)"
            )
        }

        // 5. Acquire delivery token (replaces JWT for this call).
        let deliveryToken = try await sealedSenderManager.acquireDeliveryToken()

        // 6. Build and dispatch the unauthenticated gRPC request.
        var request = Vync_Messaging_SendSealedMessageRequest()
        request.deliveryToken = deliveryToken
        request.deviceMessages = sealedDeviceMessages

        let response = try await grpcClient.messagingService.sendSealedMessage(request)

        // 7. Background-replenish the token pool.
        await sealedSenderManager.replenishIfNeeded()

        return SealedMessageSendResult(
            serverTimestampMs: response.serverTimestamp
        )
    }
}

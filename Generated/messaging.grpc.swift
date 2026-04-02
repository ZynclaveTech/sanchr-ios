import Foundation

// MARK: - vync.messaging gRPC Client
// Generated from Proto/messaging.proto — DO NOT EDIT

/// Client protocol for the MessagingService gRPC service.
protocol Vync_Messaging_MessagingServiceClientProtocol: Sendable {
    /// Sends an encrypted message to a conversation.
    func sendMessage(_ request: Vync_Messaging_SendMessageRequest) async throws -> Vync_Messaging_SendMessageResponse

    /// Creates a new direct (1:1) conversation with a recipient.
    func startDirectConversation(_ request: Vync_Messaging_StartDirectConversationRequest) async throws -> Vync_Messaging_Conversation

    /// Opens a bidirectional stream for real-time message delivery, typing, and presence.
    func messageStream(
        send: AsyncStream<Vync_Messaging_ClientEvent>
    ) async throws -> AsyncStream<Vync_Messaging_ServerEvent>

    /// Syncs messages from the server since a given timestamp (server-streaming).
    func syncMessages(_ request: Vync_Messaging_SyncRequest) async throws -> AsyncStream<Vync_Messaging_EncryptedEnvelope>

    /// Deletes a message from a conversation.
    func deleteMessage(_ request: Vync_Messaging_DeleteMessageRequest) async throws -> Vync_Messaging_DeleteMessageResponse

    /// Sends a read/delivered receipt for a message.
    func sendReceipt(_ request: Vync_Messaging_ReceiptRequest) async throws -> Vync_Messaging_ReceiptResponse

    /// Fetches all conversations for the authenticated user.
    func getConversations(_ request: Vync_Messaging_GetConversationsRequest) async throws -> Vync_Messaging_GetConversationsResponse
}

/// Concrete gRPC client for MessagingService.
final class Vync_Messaging_MessagingServiceClient: Vync_Messaging_MessagingServiceClientProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func sendMessage(_ request: Vync_Messaging_SendMessageRequest) async throws -> Vync_Messaging_SendMessageResponse {
        SanchrLogger.network.info("gRPC: MessagingService/SendMessage")
        throw AppError.serverUnreachable
    }

    func startDirectConversation(_ request: Vync_Messaging_StartDirectConversationRequest) async throws -> Vync_Messaging_Conversation {
        SanchrLogger.network.info("gRPC: MessagingService/StartDirectConversation")
        throw AppError.serverUnreachable
    }

    func messageStream(
        send: AsyncStream<Vync_Messaging_ClientEvent>
    ) async throws -> AsyncStream<Vync_Messaging_ServerEvent> {
        SanchrLogger.network.info("gRPC: MessagingService/MessageStream (bidi)")
        // TODO: Implement bidirectional streaming via gRPC channel
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func syncMessages(_ request: Vync_Messaging_SyncRequest) async throws -> AsyncStream<Vync_Messaging_EncryptedEnvelope> {
        SanchrLogger.network.info("gRPC: MessagingService/SyncMessages (server stream)")
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func deleteMessage(_ request: Vync_Messaging_DeleteMessageRequest) async throws -> Vync_Messaging_DeleteMessageResponse {
        SanchrLogger.network.info("gRPC: MessagingService/DeleteMessage")
        throw AppError.serverUnreachable
    }

    func sendReceipt(_ request: Vync_Messaging_ReceiptRequest) async throws -> Vync_Messaging_ReceiptResponse {
        SanchrLogger.network.info("gRPC: MessagingService/SendReceipt")
        throw AppError.serverUnreachable
    }

    func getConversations(_ request: Vync_Messaging_GetConversationsRequest) async throws -> Vync_Messaging_GetConversationsResponse {
        SanchrLogger.network.info("gRPC: MessagingService/GetConversations")
        throw AppError.serverUnreachable
    }
}

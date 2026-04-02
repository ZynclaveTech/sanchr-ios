import Foundation

/// Data source for chat-related gRPC service calls.
final class ChatDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    // TODO: Implement when proto-generated stubs are available
    //
    // func sendMessage(encryptedPayload: Data, conversationId: String) async throws -> MessageResponse {
    //     let request = Messaging_SendMessageRequest.with {
    //         $0.conversationID = conversationId
    //         $0.encryptedPayload = encryptedPayload
    //     }
    //     return try await grpcClient.messagingService.sendMessage(request)
    // }
    //
    // func fetchConversations() async throws -> [ConversationResponse] {
    //     let request = Messaging_FetchConversationsRequest()
    //     let response = try await grpcClient.messagingService.fetchConversations(request)
    //     return response.conversations
    // }
    //
    // func openMessageStream() -> AsyncStream<Messaging_IncomingMessage> {
    //     // Bidirectional gRPC stream
    // }
}

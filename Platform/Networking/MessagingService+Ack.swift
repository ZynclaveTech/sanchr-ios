import GRPC

extension Vync_Messaging_MessagingServiceClientInterceptorFactoryProtocol {
    func makeAckMessagesInterceptors()
        -> [ClientInterceptor<Vync_Messaging_AckMessagesRequest, Vync_Messaging_AckMessagesResponse>]
    {
        []
    }
}

extension Vync_Messaging_MessagingServiceAsyncClientProtocol {
    internal func ackMessages(
        _ request: Vync_Messaging_AckMessagesRequest,
        callOptions: CallOptions? = nil
    ) async throws -> Vync_Messaging_AckMessagesResponse {
        try await self.performAsyncUnaryCall(
            path: "/vync.messaging.MessagingService/AckMessages",
            request: request,
            callOptions: callOptions ?? self.defaultCallOptions,
            interceptors: self.interceptors?.makeAckMessagesInterceptors() ?? []
        )
    }
}

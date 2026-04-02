import Foundation

/// Data source for call signaling gRPC service calls.
final class CallDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    // TODO: Implement when proto-generated stubs are available
    //
    // func sendOffer(callId: String, sdp: String, recipientId: String) async throws {
    //     let request = Call_SignalingRequest.with {
    //         $0.callID = callId
    //         $0.sdp = sdp
    //         $0.recipientID = recipientId
    //         $0.type = .offer
    //     }
    //     try await grpcClient.callService.sendSignaling(request)
    // }
    //
    // func sendAnswer(callId: String, sdp: String, recipientId: String) async throws { ... }
    //
    // func sendIceCandidate(callId: String, candidate: String, recipientId: String) async throws { ... }
    //
    // func openSignalingStream(callId: String) -> AsyncStream<Call_SignalingMessage> { ... }
}

import Foundation
import GRPC

/// Data source wrapping the CallSignalingService gRPC client.
/// Provides typed domain-level access to call signaling, history, and TURN credentials.
final class CallDataSource: @unchecked Sendable {

    private let callService: Vync_Calling_CallSignalingServiceAsyncClientProtocol

    init(callService: Vync_Calling_CallSignalingServiceAsyncClientProtocol) {
        self.callService = callService
    }

    // MARK: - Call Signaling

    /// Sends an SDP offer to initiate a call with the specified recipient.
    func initiateCall(recipientId: String, callType: String, sdpOffer: Data) async throws
        -> Vync_Calling_CallResponse
    {
        var request = Vync_Calling_CallOffer()
        request.recipientID = recipientId
        request.callType = callType
        request.sdpOffer = sdpOffer
        return try await callService.initiateCall(request)
    }

    /// Opens a bidirectional signaling stream for exchanging SDP, ICE candidates, and control messages.
    func openCallStream(outbound: AsyncStream<Vync_Calling_CallSignal>) -> GRPCAsyncResponseStream<
        Vync_Calling_CallSignal
    > {
        return callService.callStream(outbound)
    }

    /// Sends an end-call request to the server.
    func endCall(callId: String) async throws {
        var request = Vync_Calling_EndCallRequest()
        request.callID = callId
        _ = try await callService.endCall(request)
    }

    // MARK: - Call History

    /// Fetches call history entries from the server.
    func fetchCallHistory(limit: Int32 = 50) async throws -> [Vync_Calling_CallLogEntry] {
        var request = Vync_Calling_GetCallHistoryRequest()
        request.limit = limit
        let response = try await callService.getCallHistory(request)
        return response.entries
    }

    // MARK: - TURN Credentials

    /// Fetches TURN server credentials for NAT traversal.
    func fetchTurnCredentials() async throws -> Vync_Calling_TurnCredentials {
        return try await callService.getTurnCredentials(Vync_Calling_GetTurnCredentialsRequest())
    }
}

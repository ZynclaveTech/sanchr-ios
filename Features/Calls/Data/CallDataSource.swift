import Foundation
import GRPC
import SanchrShared

/// Data source wrapping the CallSignalingService gRPC client.
/// Provides typed domain-level access to call signaling, history, and TURN credentials.
final class CallDataSource: @unchecked Sendable {

    private let callService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol

    init(callService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol) {
        self.callService = callService
    }

    // MARK: - Call Signaling

    /// Sends a sealed, Signal-encrypted call offer to the server.
    func initiateCall(
        recipientId: String,
        callType: String,
        deliveryToken: Data,
        encryptedSdpPayload: Data
    ) async throws -> Sanchr_Calling_CallResponse {
        var request = Sanchr_Calling_CallOffer()
        request.recipientID = recipientId       // kept for server backward compat
        request.callType = callType
        request.deliveryToken = deliveryToken
        request.encryptedSdpPayload = encryptedSdpPayload
        return try await callService.initiateCall(request)
    }

    /// Opens a bidirectional signaling stream for exchanging SDP, ICE candidates, and control messages.
    func openCallStream(outbound: AsyncStream<Sanchr_Calling_CallSignal>) -> GRPCAsyncResponseStream<
        Sanchr_Calling_CallSignal
    > {
        return callService.callStream(outbound)
    }

    /// Sends an end-call request to the server.
    func endCall(callId: String) async throws {
        var request = Sanchr_Calling_EndCallRequest()
        request.callID = callId
        _ = try await callService.endCall(request)
    }

    // MARK: - Call History

    /// Fetches call history entries from the server.
    func fetchCallHistory(limit: Int32 = 50) async throws -> [Sanchr_Calling_CallLogEntry] {
        var request = Sanchr_Calling_GetCallHistoryRequest()
        request.limit = limit
        let response = try await callService.getCallHistory(request)
        return response.entries
    }

    // MARK: - TURN Credentials

    /// Fetches TURN server credentials for NAT traversal.
    func fetchTurnCredentials() async throws -> Sanchr_Calling_TurnCredentials {
        return try await callService.getTurnCredentials(Sanchr_Calling_GetTurnCredentialsRequest())
    }
}

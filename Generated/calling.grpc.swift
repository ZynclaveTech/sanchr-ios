import Foundation

// MARK: - vync.calling gRPC Client
// Generated from Proto/calling.proto — DO NOT EDIT

/// Client protocol for the CallSignalingService gRPC service.
protocol Vync_Calling_CallSignalingServiceClientProtocol: Sendable {
    /// Initiates a call by sending an SDP offer to the recipient.
    func initiateCall(_ request: Vync_Calling_CallOffer) async throws -> Vync_Calling_CallResponse

    /// Opens a bidirectional stream for exchanging call signals (SDP, ICE, control).
    func callStream(
        send: AsyncStream<Vync_Calling_CallSignal>
    ) async throws -> AsyncStream<Vync_Calling_CallSignal>

    /// Ends an active call.
    func endCall(_ request: Vync_Calling_EndCallRequest) async throws -> Vync_Calling_EndCallResponse

    /// Fetches call history for the authenticated user.
    func getCallHistory(_ request: Vync_Calling_GetCallHistoryRequest) async throws -> Vync_Calling_GetCallHistoryResponse

    /// Retrieves TURN server credentials for NAT traversal.
    func getTurnCredentials(_ request: Vync_Calling_GetTurnCredentialsRequest) async throws -> Vync_Calling_TurnCredentials
}

/// Concrete gRPC client for CallSignalingService.
final class Vync_Calling_CallSignalingServiceClient: Vync_Calling_CallSignalingServiceClientProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func initiateCall(_ request: Vync_Calling_CallOffer) async throws -> Vync_Calling_CallResponse {
        SanchrLogger.network.info("gRPC: CallSignalingService/InitiateCall")
        throw AppError.serverUnreachable
    }

    func callStream(
        send: AsyncStream<Vync_Calling_CallSignal>
    ) async throws -> AsyncStream<Vync_Calling_CallSignal> {
        SanchrLogger.network.info("gRPC: CallSignalingService/CallStream (bidi)")
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func endCall(_ request: Vync_Calling_EndCallRequest) async throws -> Vync_Calling_EndCallResponse {
        SanchrLogger.network.info("gRPC: CallSignalingService/EndCall")
        throw AppError.serverUnreachable
    }

    func getCallHistory(_ request: Vync_Calling_GetCallHistoryRequest) async throws -> Vync_Calling_GetCallHistoryResponse {
        SanchrLogger.network.info("gRPC: CallSignalingService/GetCallHistory")
        throw AppError.serverUnreachable
    }

    func getTurnCredentials(_ request: Vync_Calling_GetTurnCredentialsRequest) async throws -> Vync_Calling_TurnCredentials {
        SanchrLogger.network.info("gRPC: CallSignalingService/GetTurnCredentials")
        throw AppError.serverUnreachable
    }
}

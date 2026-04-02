import Foundation

/// Data source for authentication gRPC service calls.
/// Translates between domain models and protobuf messages.
final class AuthDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    // TODO: Implement when proto-generated stubs are available
    //
    // func requestOTP(phoneNumber: String) async throws -> OTPRequestResult {
    //     let request = Auth_RequestOTPRequest.with {
    //         $0.phoneNumber = phoneNumber
    //     }
    //     let response = try await grpcClient.authService.requestOTP(request)
    //     return OTPRequestResult(
    //         requestId: response.requestID,
    //         expiresInSeconds: Int(response.expiresIn),
    //         phoneNumber: phoneNumber
    //     )
    // }
    //
    // func verifyOTP(phoneNumber: String, code: String, requestId: String) async throws -> AuthTokens {
    //     let request = Auth_VerifyOTPRequest.with {
    //         $0.phoneNumber = phoneNumber
    //         $0.code = code
    //         $0.requestID = requestId
    //     }
    //     let response = try await grpcClient.authService.verifyOTP(request)
    //     return AuthTokens(
    //         accessToken: response.accessToken,
    //         refreshToken: response.refreshToken,
    //         expiresAt: Date(timeIntervalSince1970: TimeInterval(response.expiresAt)),
    //         userId: response.userID
    //     )
    // }
}

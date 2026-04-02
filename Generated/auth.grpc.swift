import Foundation

// MARK: - vync.auth gRPC Client
// Generated from Proto/auth.proto — DO NOT EDIT

/// Client protocol for the AuthService gRPC service.
protocol Vync_Auth_AuthServiceClientProtocol: Sendable {
    /// Registers a new user account and triggers OTP verification.
    func register(_ request: Vync_Auth_RegisterRequest) async throws -> Vync_Auth_AuthResponse

    /// Verifies the OTP code sent during registration or login.
    func verifyOTP(_ request: Vync_Auth_VerifyOTPRequest) async throws -> Vync_Auth_AuthResponse

    /// Authenticates an existing user with phone number and password.
    func login(_ request: Vync_Auth_LoginRequest) async throws -> Vync_Auth_AuthResponse

    /// Refreshes an expired access token using a valid refresh token.
    func refreshToken(_ request: Vync_Auth_RefreshTokenRequest) async throws -> Vync_Auth_AuthResponse

    /// Invalidates the current session and refresh token.
    func logout(_ request: Vync_Auth_LogoutRequest) async throws -> Vync_Auth_LogoutResponse

    /// Changes the user's password.
    func changePassword(_ request: Vync_Auth_ChangePasswordRequest) async throws -> Vync_Auth_ChangePasswordResponse
}

/// Concrete gRPC client for AuthService.
/// Encodes requests as JSON, sends over the GRPCClientProtocol transport,
/// and decodes responses.
final class Vync_Auth_AuthServiceClient: Vync_Auth_AuthServiceClientProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
    }

    func register(_ request: Vync_Auth_RegisterRequest) async throws -> Vync_Auth_AuthResponse {
        SanchrLogger.network.info("gRPC: AuthService/Register")
        // TODO: Wire to actual gRPC channel call
        // let call = channel.makeUnaryCall(path: "/vync.auth.AuthService/Register", request: request)
        throw AppError.serverUnreachable
    }

    func verifyOTP(_ request: Vync_Auth_VerifyOTPRequest) async throws -> Vync_Auth_AuthResponse {
        SanchrLogger.network.info("gRPC: AuthService/VerifyOTP")
        throw AppError.serverUnreachable
    }

    func login(_ request: Vync_Auth_LoginRequest) async throws -> Vync_Auth_AuthResponse {
        SanchrLogger.network.info("gRPC: AuthService/Login")
        throw AppError.serverUnreachable
    }

    func refreshToken(_ request: Vync_Auth_RefreshTokenRequest) async throws -> Vync_Auth_AuthResponse {
        SanchrLogger.network.info("gRPC: AuthService/RefreshToken")
        throw AppError.serverUnreachable
    }

    func logout(_ request: Vync_Auth_LogoutRequest) async throws -> Vync_Auth_LogoutResponse {
        SanchrLogger.network.info("gRPC: AuthService/Logout")
        throw AppError.serverUnreachable
    }

    func changePassword(_ request: Vync_Auth_ChangePasswordRequest) async throws -> Vync_Auth_ChangePasswordResponse {
        SanchrLogger.network.info("gRPC: AuthService/ChangePassword")
        throw AppError.serverUnreachable
    }
}

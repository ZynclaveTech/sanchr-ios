import Foundation
import SanchrShared

/// Protocol for high-level authentication operations.
protocol AuthServiceProtocol: AnyObject, Sendable {
    func login(phoneNumber: String) async throws -> OTPRequestResult
    func verifyOTP(phoneNumber: String, code: String, requestId: String) async throws
    func register(phoneNumber: String, displayName: String) async throws -> OTPRequestResult
    func changePassword(currentPassword: String, newPassword: String) async throws
    func logout() async throws
}

/// Authentication service coordinating login, registration, and key exchange.
final class AuthServiceImpl: AuthServiceProtocol, @unchecked Sendable {
    private let repository: AuthRepositoryProtocol
    private let sessionService: SessionService

    init(repository: AuthRepositoryProtocol, sessionService: SessionService) {
        self.repository = repository
        self.sessionService = sessionService
    }

    func login(phoneNumber: String) async throws -> OTPRequestResult {
        SanchrLogger.auth.info("Initiating login for \(phoneNumber.prefix(4))****")
        return try await repository.requestOTP(phoneNumber: phoneNumber, displayName: nil)
    }

    func verifyOTP(phoneNumber: String, code: String, requestId: String) async throws {
        SanchrLogger.auth.info("Verifying OTP")
        let tokens = try await repository.verifyOTP(
            phoneNumber: phoneNumber,
            code: code,
            requestId: requestId
        )
        try await sessionService.storeTokens(tokens)
    }

    func register(phoneNumber: String, displayName: String) async throws -> OTPRequestResult {
        SanchrLogger.auth.info("Starting staged registration")
        return try await repository.register(phoneNumber: phoneNumber, displayName: displayName)
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {
        try await repository.changePassword(
            currentPassword: currentPassword,
            newPassword: newPassword
        )
    }

    func logout() async throws {
        SanchrLogger.auth.info("Logging out")
        try await sessionService.clearSession()
    }
}

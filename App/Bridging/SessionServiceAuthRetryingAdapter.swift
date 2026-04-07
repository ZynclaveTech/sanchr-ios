import Foundation
import SanchrShared

/// Bridges the main-app `SessionService` to the SanchrShared `AuthRetrying`
/// seam used by `DefaultEncryptedMessageSendingClient` (and any other shared
/// type that needs token-refresh-on-UNAUTHENTICATED behaviour).
///
/// `SessionService` already exposes `withAuthRetry`, but it lives in the main
/// app and pulls in app-only dependencies, so SanchrShared cannot reference
/// it directly. This adapter is a tiny shim that simply forwards through.
final class SessionServiceAuthRetryingAdapter: AuthRetrying {

    private let sessionService: SessionService

    init(sessionService: SessionService) {
        self.sessionService = sessionService
    }

    func withAuthRetry<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await sessionService.withAuthRetry(body)
    }
}

import Foundation
import SanchrShared

/// Bridges the main-app `SessionService` to the SanchrShared
/// `CurrentUserProviding` seam consumed by `MessageSender`.
///
/// `SessionService` lives in the main app and references app-only types,
/// so SanchrShared cannot import it directly. This adapter is a tiny shim
/// that exposes the currently authenticated user ID to the actor without
/// dragging the rest of the session surface across the module boundary.
///
/// `SessionService.currentUserId` is a synchronous stored property today,
/// so the adapter satisfies the `async` accessor immediately. The protocol
/// stays `async` so a future actor-isolated `SessionService` (or a share-
/// extension adapter that has to fault state in from the keychain) can
/// hop without changing the seam.
final class SessionServiceCurrentUserAdapter: CurrentUserProviding {

    private let sessionService: SessionService

    init(sessionService: SessionService) {
        self.sessionService = sessionService
    }

    var currentUserId: String? {
        get async {
            sessionService.currentUserId
        }
    }
}

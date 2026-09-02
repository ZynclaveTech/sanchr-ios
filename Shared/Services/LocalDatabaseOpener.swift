import Foundation
import SanchrShared

/// Opens the encrypted database exactly once, on whichever thread asks first.
///
/// Opening means SQLCipher key derivation plus schema migrations — long
/// enough to show as a hang on the main thread at launch, which is where the
/// container's lazy `localDatabase` used to do it. The container now starts
/// an open in the background as soon as it exists; by the time the first
/// view touches `localDatabase`, the result is usually already here. If it
/// is not, that caller joins the open in progress rather than starting a
/// second one.
final class LocalDatabaseOpener: @unchecked Sendable {
    typealias Outcome = Result<LocalDatabaseProtocol, AppError>

    private let open: @Sendable () -> Outcome
    private let lock = NSLock()
    private var outcome: Outcome?

    init(open: @escaping @Sendable () -> Outcome) {
        self.open = open
    }

    /// The opened database, opening it now if nothing has yet.
    ///
    /// The lock is held for the whole open, so a second caller blocks until
    /// the first finishes and then gets the same result.
    func result() -> Outcome {
        lock.lock()
        defer { lock.unlock() }
        if let outcome { return outcome }
        let fresh = open()
        outcome = fresh
        return fresh
    }

    /// Starts the open on a background thread.
    func prewarm() {
        Task.detached(priority: .userInitiated) { [self] in
            _ = result()
        }
    }

    /// Forgets the current database so the next `result()` opens again.
    /// Used after the database files and their key have been destroyed.
    func reset() {
        lock.lock()
        outcome = nil
        lock.unlock()
    }
}

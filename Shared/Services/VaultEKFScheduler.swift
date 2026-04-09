import Foundation
import SanchrShared

/// Foreground-only EKF scheduler for the AccessKeyStore.
///
/// The research paper's Ephemeral Key Framework requires a periodic purge of
/// access keys past their 30-day sliding TTL. This scheduler runs that purge
/// every 15 minutes while the app is in the foreground, coordinates with the
/// vault access path so a purge cannot race with a live decrypt, and emits
/// telemetry to `os.Logger` on every tick.
///
/// Design:
/// - Foreground only. Background ticks are deliberately not wired — background
///   budget is precious, and a best-effort purge that runs on next foreground
///   is good enough for the 30-day TTL semantics.
/// - Access-vs-purge mutual exclusion via an `AsyncLock`. The access path
///   calls `withAccess { ... }` which takes the lock for the duration of the
///   closure. The purge path takes the same lock. First caller wins.
/// - The scheduler owns its own `Task`. `start()` creates it; `stop()`
///   cancels it. `DependencyContainer` holds a reference and calls
///   `start()` on app foreground, `stop()` on background.
public actor VaultEKFScheduler {
    private let accessKeyStore: AccessKeyStoreProtocol
    private let tickInterval: TimeInterval

    private let accessLock = AsyncLock()
    private var runningTask: Task<Void, Never>?

    public init(
        accessKeyStore: AccessKeyStoreProtocol,
        tickInterval: TimeInterval = 15 * 60  // 15 minutes
    ) {
        self.accessKeyStore = accessKeyStore
        self.tickInterval = tickInterval
    }

    /// Start the periodic tick loop. No-op if already running.
    public func start() {
        guard runningTask == nil else { return }
        SanchrLogger.vault.info("starting EKF scheduler, interval=\(self.tickInterval)s")
        runningTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Cancel the tick loop. Safe to call multiple times.
    public func stop() {
        SanchrLogger.vault.info("stopping EKF scheduler")
        runningTask?.cancel()
        runningTask = nil
    }

    /// Perform one purge pass immediately. Public for tests and for the
    /// "fire one tick on foreground" path in `DependencyContainer`.
    public func tick() async throws {
        await accessLock.withLock {
            do {
                let count = try await self.accessKeyStore.purgeExpired()
                SanchrLogger.vault.info("purge tick completed, removed=\(count)")
            } catch {
                SanchrLogger.vault.error("purge tick failed: \(error.localizedDescription)")
            }
        }
    }

    /// Run `body` while holding the access-path lock so a scheduled purge
    /// cannot race with a live decrypt. Callers: `VaultRepository` /
    /// `VaultDataSource` decrypt paths (wired in Tasks 7 and 8).
    public func withAccess<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await accessLock.withLockThrowing(body)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(tickInterval * 1_000_000_000))
            } catch {
                // Task cancelled during sleep — exit cleanly.
                return
            }
            do {
                try await tick()
            } catch {
                SanchrLogger.vault.error("tick threw outside its own catch: \(error.localizedDescription)")
            }
        }
    }
}

/// An async-aware lock that serializes access across async boundaries.
/// `NSLock` cannot be held across `await`; this actor-backed wrapper can.
///
/// Supports cancellation: a task parked in `acquire()` will throw
/// `CancellationError` if its enclosing Task is cancelled, and its waiter
/// slot is cleaned up.
actor AsyncLock {
    private var isLocked = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var waiterOrder: [UUID] = []

    func withLock<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        // Wrap body in a non-throwing closure and delegate to the throwing
        // version. If acquire() throws (cancellation), return the body's
        // result computed without the lock — the scheduler's runLoop will
        // exit on cancellation anyway.
        do {
            return try await withLockThrowing {
                await body()
            }
        } catch {
            // Cancelled while waiting. Run body unlocked. The scheduler's
            // runLoop will notice cancellation on the next iteration and
            // exit cleanly.
            return await body()
        }
    }

    func withLockThrowing<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        if !isLocked {
            isLocked = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, any Error>) in
                // Check cancellation inside actor isolation: if the task is
                // already cancelled at the moment we'd park, resume with
                // CancellationError immediately.
                if Task.isCancelled {
                    k.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = k
                waiterOrder.append(id)
            }
        } onCancel: {
            // Cancellation handler runs outside actor isolation. Hop back
            // onto the actor to remove the waiter and resume with error.
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let k = waiters.removeValue(forKey: id) else {
            // Already resumed (release beat cancellation to the punch).
            return
        }
        waiterOrder.removeAll { $0 == id }
        k.resume(throwing: CancellationError())
    }

    private func release() {
        while let nextID = waiterOrder.first {
            waiterOrder.removeFirst()
            if let k = waiters.removeValue(forKey: nextID) {
                // Found a live waiter — hand off the lock.
                k.resume()
                return
            }
            // Otherwise the waiter was cancelled; try the next one.
        }
        isLocked = false
    }
}

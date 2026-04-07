import Foundation

/// Cross-process exclusive lock built on `NSFileCoordinator`. Both the main
/// app and the share extension acquire this before running the encrypt-and-
/// send pipeline, because Signal-protocol ratchet state mutations must be
/// atomic across the WHOLE encrypt operation, not just at the SQL row level.
///
/// SQLite WAL gives us many readers + one writer at the SQL layer; this lock
/// gives us exclusive access at the application layer.
public final class FileCoordinatorLock: @unchecked Sendable {

    private let lockURL: URL
    private let coordinator: NSFileCoordinator

    public init(lockURL: URL = AppGroup.senderLockURL) {
        self.lockURL = lockURL
        self.coordinator = NSFileCoordinator(filePresenter: nil)

        // Make sure the file exists so coordination has a target.
        if FileManager.default.fileExists(atPath: lockURL.path) == false {
            FileManager.default.createFile(atPath: lockURL.path, contents: Data())
        }
    }

    /// Run `body` while holding the cross-process lock. Suspends the calling
    /// task without blocking a thread (the file coordinator API is sync, so
    /// we hop to a background queue).
    public func withLock<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var coordError: NSError?
                var didResume = false
                self.coordinator.coordinate(
                    writingItemAt: self.lockURL,
                    options: .forReplacing,
                    error: &coordError
                ) { _ in
                    // Inside the coordinated block we have exclusive access.
                    // Bridge the async body back to this sync accessor via a
                    // semaphore. Safe because we're on a background queue.
                    let semaphore = DispatchSemaphore(value: 0)
                    nonisolated(unsafe) var result: Result<T, Error>!
                    Task { @Sendable in
                        do {
                            let value = try await body()
                            result = .success(value)
                        } catch {
                            result = .failure(error)
                        }
                        semaphore.signal()
                    }
                    semaphore.wait()
                    didResume = true
                    switch result! {
                    case .success(let v): cont.resume(returning: v)
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
                if let coordError, !didResume {
                    cont.resume(throwing: coordError)
                }
            }
        }
    }
}

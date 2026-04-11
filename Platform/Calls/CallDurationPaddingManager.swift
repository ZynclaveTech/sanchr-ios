// Platform/Calls/CallDurationPaddingManager.swift
import Foundation

/// Computes call duration padding buckets and delays peer connection teardown
/// until the next bucket boundary, hiding real call duration from the server.
final class CallDurationPaddingManager: @unchecked Sendable {

    /// Bucket boundaries in seconds: 1, 5, 15, 30, 60 minutes.
    static let buckets: [TimeInterval] = [60, 300, 900, 1800, 3600]

    private var paddingTask: Task<Void, Never>?

    /// Returns the date at which padding ends, given the actual start and end of the call.
    /// The result is `callStart + smallest_bucket_≥_duration`, capped at 60 minutes.
    static func paddingEnd(callStart: Date, callEnd: Date) -> Date {
        let duration = callEnd.timeIntervalSince(callStart)
        let bucket = buckets.first(where: { $0 >= duration }) ?? buckets.last!
        return callStart.addingTimeInterval(bucket)
    }

    /// Delays `onComplete` until `target`. If `target` is in the past, calls immediately.
    /// The caller keeps the peer connection alive until `onComplete` fires.
    func padThenComplete(target: Date, onComplete: @escaping @Sendable () -> Void) {
        paddingTask?.cancel()
        let remaining = target.timeIntervalSinceNow
        guard remaining > 0 else {
            onComplete()
            return
        }
        paddingTask = Task {
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            onComplete()
        }
    }

    /// Cancels any in-progress padding. The peer connection can be torn down immediately.
    func cancel() {
        paddingTask?.cancel()
        paddingTask = nil
    }
}

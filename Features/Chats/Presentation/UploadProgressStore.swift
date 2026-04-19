import Foundation

/// Separate @Observable store for per-message upload progress and status.
/// Extracting these out of ChatDetailViewModel avoids triggering a full
/// transcript reload on every byte-progress callback — only the UICollectionView
/// items with active uploads reconfigure.
@Observable
@MainActor
final class UploadProgressStore {
    private var progressValues: [String: Double] = [:]
    private var statusLabels: [String: String] = [:]

    /// Monotonic version — bumped when any upload state changes. UIKit
    /// consumers watch this to know when to reconfigure cells. Internally
    /// throttled so byte-progress callbacks don't thrash the version.
    private(set) var version: UInt64 = 0

    private var lastBumpDate: Date = .distantPast
    private var pendingBump: Bool = false

    /// Update progress for a message. Throttled to ~5 Hz except for terminal
    /// states (fraction >= 1.0 or explicit status), which always fire immediately.
    func update(id: String, progress: Double, status: String?) {
        let previousProgress = progressValues[id]
        let previousStatus = statusLabels[id]
        progressValues[id] = progress
        if let status {
            statusLabels[id] = status
        }

        let isTerminal = progress >= 1.0
        let statusChanged = status != nil && previousStatus != status
        let bigProgressDelta = previousProgress.map { abs($0 - progress) >= 0.05 } ?? true

        if isTerminal || statusChanged || bigProgressDelta {
            bumpNow()
        } else {
            scheduleBump()
        }
    }

    /// Explicitly set a status label (e.g. "Encrypting...", "Failed") without
    /// touching progress. Always fires an immediate version bump.
    func setStatus(id: String, status: String) {
        statusLabels[id] = status
        bumpNow()
    }

    /// Clear upload state for a message (on send success or error).
    func clear(id: String) {
        progressValues.removeValue(forKey: id)
        statusLabels.removeValue(forKey: id)
        bumpNow()
    }

    func progress(for id: String) -> Double? {
        progressValues[id]
    }

    func statusLabel(for id: String) -> String? {
        statusLabels[id]
    }

    /// Snapshot of all active uploads. UIKit code uses this to know which
    /// item IDs need reconfiguration.
    var activeUploadIds: Set<String> {
        Set(progressValues.keys).union(statusLabels.keys)
    }

    private func bumpNow() {
        lastBumpDate = Date()
        pendingBump = false
        version &+= 1
    }

    private func scheduleBump() {
        let elapsed = Date().timeIntervalSince(lastBumpDate)
        if elapsed >= 0.2 {
            bumpNow()
            return
        }
        guard !pendingBump else { return }
        pendingBump = true
        let delay = 0.2 - elapsed
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.pendingBump else { return }
            self.bumpNow()
        }
    }
}

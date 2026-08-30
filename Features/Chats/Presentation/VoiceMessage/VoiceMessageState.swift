import Foundation
import CoreGraphics
import SanchrShared

struct Recording: Equatable, Sendable {
    let url: URL
    let durationMs: Int
    /// Normalized waveform samples. Expected range `0...1`, length `64`.
    let waveform: [Float]
}

enum VoiceMessageState: Equatable, Sendable {
    case idle
    case recording(startedAt: Date, dragOffset: CGSize, locked: Bool)
    case preview(Recording)
}

struct ReleaseOutcome: Equatable, Sendable {
    let state: VoiceMessageState
    let shouldShowTooShortToast: Bool
}

extension VoiceMessageState {

    static let cancelDragThreshold: CGFloat = -80
    static let lockDragThreshold: CGFloat = -80
    static let minRecordingDuration: TimeInterval = 1.0

    /// - Parameter locked: start already locked. There is no finger to hold
    ///   when recording is started from a VoiceOver action, so the hands-free
    ///   state is the only one that can be operated.
    func applyPress(at now: Date, locked: Bool = false) -> VoiceMessageState {
        guard case .idle = self else { return self }
        return .recording(startedAt: now, dragOffset: .zero, locked: locked)
    }

    /// Abandon an in-progress recording. Locked recordings have no other way
    /// out: the finger that could have slid to cancel is long gone.
    func applyCancel() -> VoiceMessageState {
        guard case .recording = self else { return self }
        return .idle
    }

    func applyDrag(_ offset: CGSize) -> VoiceMessageState {
        guard case .recording(let startedAt, _, let locked) = self else { return self }
        if locked { return self }
        if offset.width <= Self.cancelDragThreshold { return .idle }
        if offset.height <= Self.lockDragThreshold {
            return .recording(startedAt: startedAt, dragOffset: offset, locked: true)
        }
        return .recording(startedAt: startedAt, dragOffset: offset, locked: false)
    }

    func applyRelease(now: Date, recording: Recording) -> ReleaseOutcome {
        guard case .recording(let startedAt, _, let locked) = self else {
            return ReleaseOutcome(state: self, shouldShowTooShortToast: false)
        }
        if locked {
            return ReleaseOutcome(state: self, shouldShowTooShortToast: false)
        }
        let elapsed = now.timeIntervalSince(startedAt)
        if elapsed < Self.minRecordingDuration {
            return ReleaseOutcome(state: .idle, shouldShowTooShortToast: true)
        }
        return ReleaseOutcome(state: .preview(recording), shouldShowTooShortToast: false)
    }

    func applyLockedStop(recording: Recording) -> VoiceMessageState {
        guard case .recording(_, _, let locked) = self, locked else { return self }
        return .preview(recording)
    }

    /// Promotes an in-progress recording to `.preview` regardless of elapsed time.
    /// Per spec, interruption sources (audio session interruption, app backgrounding,
    /// route changes, etc.) auto-promote to preview to avoid losing the recording.
    /// The `minRecordingDuration` floor only applies to user-initiated release.
    func applyInterruption(recording: Recording) -> VoiceMessageState {
        guard case .recording = self else { return self }
        return .preview(recording)
    }

    func applyDiscard() -> VoiceMessageState {
        guard case .preview = self else { return self }
        return .idle
    }

    func applySend() -> VoiceMessageState {
        guard case .preview = self else { return self }
        return .idle
    }
}

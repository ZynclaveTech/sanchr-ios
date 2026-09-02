import SwiftUI
import SanchrShared

/// The bar shown while a voice message is being recorded.
///
/// Follows Signal's `VoiceMemoLockView`: a lock above a chevron in a capsule
/// that rises with the finger, the gap between the two icons closing to
/// nothing as the gesture completes, so the drag has somewhere to arrive
/// rather than just fading.
struct RecordingHUD: View {
    /// When recording began. The HUD derives the clock from this itself.
    ///
    /// It used to be handed a pre-computed `elapsed`, recomputed only when the
    /// composer's body happened to run again — which was driven by mutating a
    /// `@State` that the body never read. SwiftUI has no reason to re-evaluate
    /// a view over state it does not consume, so the timer sat at 0:00 and the
    /// waveform never moved.
    let startedAt: Date
    let liveSamples: [Float]
    let dragOffset: CGSize
    let locked: Bool
    let onStop: () -> Void
    let onCancel: () -> Void

    /// Signal's `initialIconSpacing`, closing to 0 as the lock is reached.
    private static let lockIconSpacing: CGFloat = 16
    private static let waveformHeight: CGFloat = 28
    /// How far the lock capsule itself lifts. Small on purpose: the closing
    /// icon gap is what signals progress.
    private static let lockRise: CGFloat = -10

    /// How far through the lock gesture the finger is, 0...1.
    private var lockProgress: CGFloat {
        min(1, abs(min(0, dragOffset.height)) / abs(VoiceMessageState.lockDragThreshold))
    }

    private var cancelProgress: CGFloat {
        min(1, abs(min(0, dragOffset.width)) / abs(VoiceMessageState.cancelDragThreshold))
    }

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
            content(elapsed: max(0, context.date.timeIntervalSince(startedAt)))
        }
    }

    private func content(elapsed: TimeInterval) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(locked ? 1 : 0.6 + 0.4 * sin(elapsed * 4))
                .accessibilityHidden(true)

            Text(Self.formatTime(elapsed))
                .font(SanchrTypography.scaled(size: 15, weight: .regular).monospacedDigit())
                .monospacedDigit()
                .foregroundColor(SanchrExportColors.textPrimary)
                .accessibilityHidden(true)

            VoiceWaveformView(samples: Array(liveSamples.suffix(24)), progress: 0)
                .frame(height: Self.waveformHeight)
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            if locked {
                Button(action: onCancel) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                // Locked recording had no way out but to stop and then discard
                // in the preview. The finger that could have slid to cancel is
                // gone by then.
                .accessibilityLabel("Delete recording")

                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Slide to cancel")
                }
                .font(.system(size: 13))
                .foregroundColor(SanchrExportColors.textSecondary)
                .opacity(1 - cancelProgress)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topTrailing) { lockAffordance }
        // One element rather than five fragments, and — critically — with
        // actions. A VoiceOver user cannot slide to cancel or slide to lock,
        // so without these there was no way to end a recording at all.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(locked ? "Recording, hands free" : "Recording")
        .accessibilityValue(Self.spokenDuration(elapsed))
        .accessibilityAction(named: "Stop recording", onStop)
        .accessibilityAction(named: "Delete recording", onCancel)
    }

    /// Signal's lock capsule: the lock, then a chevron pointing at it, the gap
    /// between them closing as the finger arrives.
    @ViewBuilder
    private var lockAffordance: some View {
        if !locked {
            VStack(spacing: Self.lockIconSpacing * (1 - lockProgress)) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(SanchrColors.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(SanchrExportColors.surface, in: Capsule())
            // Signal moves the *icons* rather than the capsule — the gap
            // above closes as the finger arrives. Travelling the full gesture
            // distance would fling this a hundred points over the transcript.
            .offset(y: -40 + Self.lockRise * lockProgress)
            .opacity(lockProgress)
            .accessibilityHidden(true)
        }
    }

    private static func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "1 minute, 5 seconds" rather than "1:05", which VoiceOver reads as a
    /// time of day.
    static func spokenDuration(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        let minutes = total / 60
        let seconds = total % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        parts.append("\(seconds) second\(seconds == 1 ? "" : "s")")
        return parts.joined(separator: ", ")
    }
}

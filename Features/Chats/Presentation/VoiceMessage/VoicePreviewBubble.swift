import SwiftUI
import SanchrShared

/// A finished recording, before it is sent.
///
/// Follows Signal's `VoiceMessageDraftView`: play/pause, waveform, and the
/// time remaining rather than the total — while playing back, what you want to
/// know is how much is left.
struct VoicePreviewBubble: View {
    let recording: Recording
    let playback: VoicePlaybackController
    let onDiscard: () -> Void
    let onSend: () -> Void

    private let previewMessageId = "voice-preview"

    /// Signal's `VoiceMessageDraftView` metrics.
    private static let waveformHeight: CGFloat = 28
    private static let stackSpacing: CGFloat = 12

    private var duration: TimeInterval { Double(recording.durationMs) / 1000 }

    /// Counts down, as Signal's does: `duration - currentTime`.
    private var remaining: TimeInterval {
        max(0, duration - duration * playback.progress)
    }

    var body: some View {
        HStack(spacing: Self.stackSpacing) {
            Button(action: onDiscard) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete recording")

            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(SanchrColors.primary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            waveform

            Text(Self.formatTime(remaining))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(SanchrExportColors.textSecondary)
                .accessibilityHidden(true)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        LinearGradient(colors: [SanchrColors.primary, SanchrColors.primaryDark],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send voice message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Scrubbing needs the waveform's own width.
    ///
    /// It used to compute one from the gesture: `translation.width +
    /// startLocation.x`, which is the algebraic definition of `location.x` —
    /// so the fraction was `location.x / location.x`, and every scrub jumped
    /// to the end of the clip.
    private var waveform: some View {
        GeometryReader { proxy in
            VoiceWaveformView(samples: recording.waveform, progress: playback.progress)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let fraction = max(0, min(1, g.location.x / max(1, proxy.size.width)))
                            playback.seek(to: fraction)
                        }
                )
        }
        .frame(height: Self.waveformHeight)
        .accessibilityElement()
        .accessibilityLabel("Recording")
        .accessibilityValue("\(RecordingHUD.spokenDuration(duration)) remaining \(RecordingHUD.spokenDuration(remaining))")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment: playback.seek(to: min(1, playback.progress + step))
            case .decrement: playback.seek(to: max(0, playback.progress - step))
            @unknown default: break
            }
        }
    }

    private var isPlaying: Bool { playback.currentlyPlayingMessageId == previewMessageId }

    private func togglePlayback() {
        if isPlaying { playback.pause() }
        else { try? playback.play(url: recording.url, messageId: previewMessageId) }
    }

    private static func formatTime(_ t: Double) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

import SwiftUI
import SanchrShared

/// A received or sent voice note inside its message bubble.
struct VoicePlaybackBubble: View {
    let messageId: String
    let url: URL
    let durationMs: Int
    let waveform: [Float]
    let isOutgoing: Bool
    let playback: VoicePlaybackController

    /// Decoded on demand when the message arrived without one, which is every
    /// voice note that came from someone else.
    @State private var decoded: [Float] = []

    private var samples: [Float] { waveform.isEmpty ? decoded : waveform }

    private var duration: TimeInterval { Double(durationMs) / 1000 }

    /// Playback position, kept while paused. It used to be forced to zero
    /// whenever this was not the playing message, so pausing threw away the
    /// position it had just shown you.
    private var progress: Double {
        isCurrent ? playback.progress : 0
    }

    /// Counts down while playing, as Signal's does — what you want to know
    /// part-way through is how much is left.
    private var displayedTime: TimeInterval {
        isCurrent ? max(0, duration - duration * playback.progress) : duration
    }

    /// Inherits the bubble's own text colour. The play button was always the
    /// accent, which on an outgoing bubble is purple on purple.
    private var tint: Color {
        isOutgoing ? .white : SanchrExportColors.textPrimary
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: togglePlayback) {
                Image(systemName: isCurrent && playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrent && playback.isPlaying ? "Pause" : "Play")

            waveformStrip

            Text(Self.formatTime(displayedTime))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(tint.opacity(0.7))
                // The bubble hugs its content, and a monospaced clock is happy
                // to wrap into "0:" over "14" if it is given the chance.
                .fixedSize()
                .accessibilityHidden(true)
        }
        // No background, no corner radius, no padding of its own. Audio takes
        // `.standard` chrome, so the message bubble already draws all three —
        // this was painting a second rounded box inside the first, which on an
        // outgoing bubble read as a grey slab on the gradient.
        .task(id: url) {
            guard waveform.isEmpty else { return }
            decoded = await VoiceWaveformCache.shared.waveform(for: url)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice message")
        .accessibilityValue(Self.spokenDuration(duration))
    }

    /// Scrubbing needs the strip's own width.
    ///
    /// It divided by `translation.width + startLocation.x`, which is the
    /// algebraic definition of `location.x` — so the fraction was
    /// `location.x / location.x` and every scrub jumped to the end. The same
    /// bug was fixed in the recording preview; this copy was missed.
    private var waveformStrip: some View {
        GeometryReader { proxy in
            VoiceWaveformView(
                samples: samples,
                progress: progress,
                playedColor: tint,
                unplayedColor: tint.opacity(0.3)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard isCurrent else { return }
                        playback.seek(to: max(0, min(1, g.location.x / max(1, proxy.size.width))))
                    }
            )
        }
        // A `GeometryReader` reports no ideal width, so the row collapsed
        // around it and the waveform came out a sliver. The strip claims a
        // width of its own; the cap keeps a long note from filling the screen.
        .frame(minWidth: Self.minimumStripWidth, maxWidth: Self.maximumStripWidth, minHeight: 28, maxHeight: 28)
    }

    private static let minimumStripWidth: CGFloat = 118
    private static let maximumStripWidth: CGFloat = 168

    private var isCurrent: Bool { playback.currentlyPlayingMessageId == messageId }

    private func togglePlayback() {
        if isCurrent && playback.isPlaying { playback.pause() }
        else { try? playback.play(url: url, messageId: messageId) }
    }

    private static func formatTime(_ t: Double) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "1 minute, 5 seconds" — VoiceOver reads "1:05" as a time of day.
    static func spokenDuration(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        parts.append("\(seconds) second\(seconds == 1 ? "" : "s")")
        return parts.joined(separator: ", ")
    }
}

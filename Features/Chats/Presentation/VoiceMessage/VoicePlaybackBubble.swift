import SwiftUI
import SanchrShared

struct VoicePlaybackBubble: View {
    let messageId: String
    let url: URL
    let durationMs: Int
    let waveform: [Float]
    let playback: VoicePlaybackController

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(SanchrColors.primary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VoiceWaveformView(samples: waveform, progress: isPlaying ? playback.progress : 0)
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let width = max(1, g.translation.width + g.startLocation.x)
                            playback.seek(to: max(0, min(1, g.location.x / width)))
                        }
                )

            Text(Self.formatTime(Double(durationMs) / 1000))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var isPlaying: Bool { playback.currentlyPlayingMessageId == messageId }

    private func togglePlayback() {
        if isPlaying { playback.pause() }
        else { try? playback.play(url: url, messageId: messageId) }
    }

    private static func formatTime(_ t: Double) -> String {
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

import SwiftUI

struct VoicePreviewBubble: View {
    let recording: Recording
    let playback: VoicePlaybackController
    let onDiscard: () -> Void
    let onSend: () -> Void

    private let previewMessageId = "voice-preview"

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onDiscard) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(SanchrColors.primary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VoiceWaveformView(samples: recording.waveform, progress: playback.progress)
                .frame(height: 32)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let width = max(1, g.translation.width + g.startLocation.x)
                            let f = max(0, min(1, g.location.x / width))
                            playback.seek(to: f)
                        }
                )

            Text(Self.formatTime(Double(recording.durationMs) / 1000))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(SanchrExportColors.textSecondary)

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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var isPlaying: Bool { playback.currentlyPlayingMessageId == previewMessageId }

    private func togglePlayback() {
        if isPlaying { playback.pause() }
        else { try? playback.play(url: recording.url, messageId: previewMessageId) }
    }

    private static func formatTime(_ t: Double) -> String {
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

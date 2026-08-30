import SwiftUI
import SanchrShared

/// Pure SwiftUI Canvas renderer for voice-message waveforms. Used by:
/// - RecordingHUD (live samples, no progress)
/// - VoicePreviewBubble (decoded samples + scrub progress)
/// - VoicePlaybackBubble (decoded samples + playback progress)
struct VoiceWaveformView: View {
    let samples: [Float]
    let progress: Double          // 0...1; pass 0 for no progress overlay
    /// Defaults preserve the recording HUD and preview; the message bubble
    /// passes its own, since a fixed grey is muddy on the outgoing gradient.
    var playedColor: Color = .accentColor
    var unplayedColor: Color = Color(uiColor: .systemGray3)
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 2
    var minBarHeight: CGFloat = 2

    /// Whether a bar at `barX` falls before the playback head.
    ///
    /// Strictly less than. The first bar sits at x = 0, so `<=` counted it as
    /// played at progress 0 — every un-played waveform carried a stray
    /// coloured tick, including the live one during recording, which has no
    /// progress at all and documents itself as taking 0 for exactly that.
    static func isPlayed(barX: CGFloat, progressX: CGFloat) -> Bool {
        barX < progressX
    }

    var body: some View {
        GeometryReader { proxy in
            Canvas { ctx, size in
                let usableWidth = size.width
                let stride = barWidth + barSpacing
                let drawable = Int(usableWidth / stride)
                let count = min(drawable, samples.count)
                let strideStep = max(1, samples.count / max(1, count))
                let progressX = usableWidth * CGFloat(progress)
                // With nothing to draw, a flat run of bars rather than a void.
                // A voice note whose waveform is still being decoded, or whose
                // audio would not decode at all, otherwise showed a blank gap
                // that reads as a broken bubble rather than a quiet one.
                let placeholder = samples.isEmpty
                let barCount = placeholder ? max(0, Int(usableWidth / stride)) : count
                for i in 0..<barCount {
                    let raw: CGFloat
                    if placeholder {
                        raw = 0
                    } else {
                        let sampleIndex = min(samples.count - 1, i * strideStep)
                        raw = CGFloat(samples[sampleIndex])
                    }
                    let h = max(minBarHeight, raw * size.height)
                    let x = CGFloat(i) * stride
                    let y = (size.height - h) / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: h)
                    let isPlayed = Self.isPlayed(barX: x, progressX: progressX)
                    let color: Color = isPlayed ? playedColor : unplayedColor
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                }
            }
        }
    }
}

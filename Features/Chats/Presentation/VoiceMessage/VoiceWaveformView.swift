import SwiftUI

/// Pure SwiftUI Canvas renderer for voice-message waveforms. Used by:
/// - RecordingHUD (live samples, no progress)
/// - VoicePreviewBubble (decoded samples + scrub progress)
/// - VoicePlaybackBubble (decoded samples + playback progress)
struct VoiceWaveformView: View {
    let samples: [Float]
    let progress: Double          // 0...1; pass 0 for no progress overlay
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 2
    var minBarHeight: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            Canvas { ctx, size in
                guard !samples.isEmpty else { return }
                let usableWidth = size.width
                let stride = barWidth + barSpacing
                let drawable = Int(usableWidth / stride)
                let count = min(drawable, samples.count)
                let strideStep = max(1, samples.count / max(1, count))
                let progressX = usableWidth * CGFloat(progress)
                for i in 0..<count {
                    let sampleIndex = min(samples.count - 1, i * strideStep)
                    let raw = CGFloat(samples[sampleIndex])
                    let h = max(minBarHeight, raw * size.height)
                    let x = CGFloat(i) * stride
                    let y = (size.height - h) / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: h)
                    let isPlayed = x <= progressX
                    let color: Color = isPlayed ? .accentColor : Color(uiColor: .systemGray3)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                }
            }
        }
    }
}

import SwiftUI
import SanchrShared

struct RecordingHUD: View {
    let elapsed: TimeInterval
    let liveSamples: [Float]
    let dragOffset: CGSize
    let locked: Bool
    let onLockedStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(locked ? 1 : 0.6 + 0.4 * sin(elapsed * 4))

            Text(Self.formatTime(elapsed))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)

            VoiceWaveformView(samples: Array(liveSamples.suffix(24)), progress: 0)
                .frame(height: 28)

            Spacer()

            if locked {
                Button(action: onLockedStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Slide to cancel")
                }
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .opacity(1 - min(1, abs(dragOffset.width) / 80))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if !locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SanchrColors.primary)
                    .padding(8)
                    .background(SanchrExportColors.surface)
                    .clipShape(Circle())
                    .offset(y: -36 + dragOffset.height.clamped(min: -80, max: 0))
                    .opacity(min(1, abs(dragOffset.height) / 80))
            }
        }
    }

    private static func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension CGFloat {
    func clamped(min lo: CGFloat, max hi: CGFloat) -> CGFloat { Swift.max(lo, Swift.min(hi, self)) }
}

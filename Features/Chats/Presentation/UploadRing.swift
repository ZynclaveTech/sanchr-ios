import SanchrShared
import SwiftUI

/// The upload indicator on an outgoing media or document bubble: a thin ring
/// that fills as bytes go out, the way Signal draws it. Before the first
/// byte (encrypting, waiting for the presigned URL) there is nothing to
/// fill, so the ring spins instead of sitting empty and looking stuck.
struct UploadRing: View {
    let progress: Double
    var tint: Color = .white
    var diameter: CGFloat = 36
    var lineWidth: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.3), lineWidth: lineWidth)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: min(progress, 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spinning && !reduceMotion ? 360 : 0))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false),
                        value: spinning
                    )
                    .onAppear { spinning = true }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel(progress > 0 ? "Uploading, \(Int(progress * 100)) percent" : "Preparing upload")
    }
}

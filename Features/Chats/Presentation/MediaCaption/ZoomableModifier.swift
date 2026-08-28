import SwiftUI

/// Pinch-to-zoom with pan, plus double-tap to toggle, for a static image.
///
/// Deliberately not a `ScrollView`: the media screens sit inside a
/// `fullScreenCover` over a horizontal filmstrip, and a nested scroll view
/// swallows the swipes those rely on. A gesture pair keeps the zoom local to
/// the image.
struct ZoomableModifier: ViewModifier {
    /// Past this, panning is allowed; at or below it the image is re-centred so
    /// it can never drift away from the middle while fully zoomed out.
    private static let minScale: CGFloat = 1
    private static let maxScale: CGFloat = 5
    private static let doubleTapScale: CGFloat = 2.5

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = clampedScale(committedScale * value)
                        }
                        .onEnded { _ in
                            committedScale = scale
                            settle()
                        },
                    DragGesture()
                        .onChanged { value in
                            // Panning only makes sense once the image is larger
                            // than its frame; otherwise a stray swipe would
                            // slide a fully visible photo off-centre.
                            guard committedScale > Self.minScale else { return }
                            offset = CGSize(
                                width: committedOffset.width + value.translation.width,
                                height: committedOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in committedOffset = offset }
                )
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    if committedScale > Self.minScale {
                        reset()
                    } else {
                        scale = Self.doubleTapScale
                        committedScale = Self.doubleTapScale
                    }
                }
            }
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.85), value: scale)
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, Self.minScale), Self.maxScale)
    }

    /// Snaps back to centre when the pinch ends at or below 1×, so a zoomed-out
    /// image is never left off-centre.
    private func settle() {
        if committedScale <= Self.minScale {
            withAnimation(.easeOut(duration: 0.2)) { reset() }
        }
    }

    private func reset() {
        scale = Self.minScale
        committedScale = Self.minScale
        offset = .zero
        committedOffset = .zero
    }
}

extension View {
    /// Adds pinch-to-zoom, pan while zoomed, and double-tap to toggle.
    func zoomable() -> some View {
        modifier(ZoomableModifier())
    }
}

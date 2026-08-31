import AVFoundation
import CoreGraphics
import SwiftUI

/// Whether a preview should fill its screen or fit inside it.
///
/// The close button and caption row are pinned to the screen, so black bands
/// leave them stranded away from the picture's actual edges. Filling removes
/// the bands — but filling a wide clip into a tall screen crops away most of
/// it, which is worse than a band.
///
/// So: fill when the shapes are close enough that little is lost, fit when
/// they are not.
enum MediaAspectFill {

    /// How far the two shapes may differ before cropping costs too much.
    ///
    /// At 0.25 a 9:16 clip fills a 9:19.5 screen — the case that looked right
    /// already — and a 4:3 clip does not, since filling it would hide about a
    /// third of the frame.
    static let maximumCropDivergence: CGFloat = 0.25

    struct Ratio {
        let contentMode: ContentMode
    }

    static func presentationRatio(content: CGFloat?, container: CGSize) -> Ratio {
        guard let content, content > 0, container.width > 0, container.height > 0 else {
            return Ratio(contentMode: .fit)
        }
        let containerRatio = container.width / container.height
        // Compared as a proportion, not a difference: the gap between 0.5 and
        // 0.6 matters far more than the same gap between 2.5 and 2.6.
        let divergence = abs(content - containerRatio) / max(content, containerRatio)
        return Ratio(contentMode: divergence <= maximumCropDivergence ? .fill : .fit)
    }

    /// The clip's displayed width ÷ height, accounting for its rotation — a
    /// portrait video is stored landscape with a transform, and reading the
    /// natural size alone reports it the wrong way round.
    static func aspectRatio(ofVideoAt url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let displayed = size.applying(transform)
        let width = abs(displayed.width)
        let height = abs(displayed.height)
        guard width > 0, height > 0 else { return nil }
        return width / height
    }
}

import CoreGraphics

/// Geometry for a zoomable image page.
///
/// The scrollable content has to be the image and nothing else. Sizing the
/// image view to the whole viewport and relying on `.scaleAspectFit` looks
/// identical at rest, but the empty bars either side of the picture become part
/// of what scrolls — so zooming in and dragging pushed the photo off into black
/// space. Photos.app stops at the edge of the picture, and so should this.
enum GalleryImageLayout {

    /// The largest rect of `imageSize`'s aspect ratio that fits inside
    /// `viewport`.
    ///
    /// Falls back to the viewport when either size is degenerate: a zero here
    /// would collapse the page to nothing, and showing the image slightly wrong
    /// beats showing no image at all.
    static func fittedSize(for imageSize: CGSize?, in viewport: CGSize) -> CGSize {
        guard let imageSize,
              imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0
        else {
            return viewport
        }

        let scale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        return CGSize(
            width: (imageSize.width * scale).rounded(),
            height: (imageSize.height * scale).rounded()
        )
    }
}

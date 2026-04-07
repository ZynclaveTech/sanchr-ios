import SwiftUI
import UIKit

/// Zoom + pan + double-tap-to-zoom image page. A `UIScrollView` wraps a
/// `UIImageView`; the SwiftUI-side binding lets us swap the image in
/// asynchronously as the decrypted file lands.
///
/// SwiftUI's `ScrollView` can't deliver all three behaviors simultaneously
/// (pinch + pan centered when zoomed below fill + double-tap zoom point)
/// without dropping frames, so we hand-build the recipe in UIKit.
struct GalleryImageView: UIViewRepresentable {
    let image: UIImage?

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView()
    }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        view.setImage(image)
    }
}

/// Standalone UIKit view so the layout + zoom math can be tested
/// independently of SwiftUI wiring later if needed.
final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .clear
        delegate = self

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if imageView.image != nil {
            imageView.frame = bounds
            centerImage()
        }
    }

    func setImage(_ image: UIImage?) {
        imageView.image = image
        setZoomScale(1, animated: false)
        setNeedsLayout()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    /// Recenter the image when zoomed out below fill so it doesn't stick
    /// to the top-left corner.
    private func centerImage() {
        let boundsSize = bounds.size
        var frameToCenter = imageView.frame
        frameToCenter.origin.x = frameToCenter.width < boundsSize.width
            ? (boundsSize.width - frameToCenter.width) / 2
            : 0
        frameToCenter.origin.y = frameToCenter.height < boundsSize.height
            ? (boundsSize.height - frameToCenter.height) / 2
            : 0
        imageView.frame = frameToCenter
    }

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let point = gr.location(in: imageView)
            let targetScale: CGFloat = 3
            let rect = zoomRect(forScale: targetScale, center: point)
            zoom(to: rect, animated: true)
        }
    }

    private func zoomRect(forScale scale: CGFloat, center: CGPoint) -> CGRect {
        let size = CGSize(
            width: bounds.width / scale,
            height: bounds.height / scale
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

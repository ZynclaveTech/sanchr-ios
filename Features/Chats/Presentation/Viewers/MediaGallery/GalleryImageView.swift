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
    /// Reports whether the page is zoomed in.
    ///
    /// The gallery needs this to know whether a drag belongs to it or to this
    /// scroll view: at rest a downward drag dismisses the viewer, but once the
    /// image is zoomed every drag is a pan and the viewer must keep its hands
    /// off.
    var onZoomChange: ((Bool) -> Void)?

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        let view = ZoomableImageScrollView()
        view.onZoomChange = onZoomChange
        return view
    }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        view.onZoomChange = onZoomChange
        view.setImage(image)
    }
}

/// Standalone UIKit view so the layout + zoom math can be tested
/// independently of SwiftUI wiring later if needed.
final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onZoomChange: ((Bool) -> Void)?

    private var isZoomed = false {
        didSet {
            guard isZoomed != oldValue else { return }
            onZoomChange?(isZoomed)
        }
    }

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
        guard imageView.image != nil else { return }

        // Only while at rest. During a zoom the scroll view is driving this
        // view's frame itself, and overwriting it here would fight the pinch.
        if zoomScale == 1 {
            imageView.frame = CGRect(
                origin: .zero,
                size: GalleryImageLayout.fittedSize(for: imageView.image?.size, in: bounds.size)
            )
            contentSize = imageView.frame.size
        }
        centerImage()
    }

    func setImage(_ image: UIImage?) {
        imageView.image = image
        setZoomScale(1, animated: false)
        isZoomed = false
        setNeedsLayout()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        // A hair above 1: bouncesZoom lets the scale drift a fraction past the
        // minimum during a pinch, and treating that as "zoomed" would leave
        // swipe-to-dismiss disabled after the image has settled back.
        isZoomed = zoomScale > 1.01
    }

    /// Keeps the image centred when it is smaller than the viewport.
    ///
    /// Done with `contentInset` rather than by nudging the image's frame,
    /// because the frame is what bounds the pan: padding it out to the
    /// viewport would put empty space back inside the scrollable area, which
    /// is the whole problem this avoids.
    private func centerImage() {
        let horizontal = max(0, (bounds.width - imageView.frame.width) / 2)
        let vertical = max(0, (bounds.height - imageView.frame.height) / 2)
        contentInset = UIEdgeInsets(
            top: vertical,
            left: horizontal,
            bottom: vertical,
            right: horizontal
        )
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

import CoreGraphics

/// Rules for the gallery's swipe-to-dismiss drag.
///
/// Pulled out of the view because the viewer has three things competing for the
/// same one-finger drag — paging between photos, panning a zoomed one, and
/// dragging the whole viewer away — and getting the split wrong silently breaks
/// two of them. It did: the dismiss drag was attached as a *high priority*
/// gesture, so it claimed every drag before the page view or the zoomed image
/// could see it. Swiping between photos and panning a zoomed photo both did
/// nothing at all. Pinch survived only because it takes two fingers.
enum GalleryDragPolicy {

    /// Slack before a drag is considered started, so a tap that wobbles a
    /// point or two is still a tap.
    static let minimumDistance: CGFloat = 12

    /// How far down the viewer must travel to dismiss on release.
    static let dismissDistance: CGFloat = 120

    /// The same, for a flick: a short fast drag whose projected end is well
    /// past the threshold counts even though the finger never got there.
    static let dismissPredictedDistance: CGFloat = 240

    /// Distance over which the backdrop fades out completely.
    static let fadeDistance: CGFloat = 400

    /// Whether a drag belongs to the viewer rather than the pager.
    ///
    /// Decided once, on the first movement, and then held for the rest of the
    /// drag. Re-deciding every frame would let a sideways swipe that sagged a
    /// little turn into a dismiss halfway through a page turn.
    static func isVertical(_ translation: CGSize) -> Bool {
        abs(translation.height) > abs(translation.width)
    }

    static func shouldDismiss(translation: CGSize, predictedEnd: CGSize) -> Bool {
        translation.height > dismissDistance || predictedEnd.height > dismissPredictedDistance
    }

    /// Backdrop opacity for a drag that has fallen `drop` points.
    static func backgroundOpacity(forDrop drop: CGFloat) -> Double {
        max(0, 1 - Double(drop / fadeDistance))
    }
}

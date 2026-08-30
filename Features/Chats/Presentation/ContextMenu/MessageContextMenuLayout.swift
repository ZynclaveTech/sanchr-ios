import CoreGraphics

/// Where the reaction bar, the lifted message and the actions menu sit.
///
/// Pulled out of the view because it is the part that goes wrong. A message
/// long-pressed near the top has no room for a reaction bar above it; one near
/// the bottom has none for a menu below. Both have to resolve to something on
/// screen, and neither case is reachable from a preview.
enum MessageContextMenuLayout {

    /// Gap between the message and each accessory.
    static let spacing: CGFloat = 10

    /// Kept clear of the screen edges so nothing collides with the notch or the
    /// home indicator.
    static let screenMargin: CGFloat = 12

    struct Result: Equatable {
        /// Vertical offset applied to the whole group — message and both
        /// accessories move together, so the message stays where the finger
        /// left it whenever it can.
        let verticalOffset: CGFloat
        /// True when the group is taller than the screen and had to be anchored
        /// to the top, with the menu scrolling instead.
        let isScrollRequired: Bool
    }

    static func resolve(
        messageFrame: CGRect,
        reactionBarHeight: CGFloat,
        menuHeight: CGFloat,
        safeArea: CGRect
    ) -> Result {
        let groupTop = messageFrame.minY - reactionBarHeight - spacing
        let groupBottom = messageFrame.maxY + spacing + menuHeight
        let groupHeight = groupBottom - groupTop

        let available = safeArea.height - screenMargin * 2
        guard groupHeight <= available else {
            // Taller than the screen: pin the top and let the menu scroll.
            // Sliding it up until the menu fits would push the message off the
            // top, losing the thing being acted on.
            return Result(
                verticalOffset: safeArea.minY + screenMargin - groupTop,
                isScrollRequired: true
            )
        }

        let topLimit = safeArea.minY + screenMargin
        let bottomLimit = safeArea.maxY - screenMargin
        var offset: CGFloat = 0

        if groupTop < topLimit {
            offset = topLimit - groupTop
        } else if groupBottom > bottomLimit {
            offset = bottomLimit - groupBottom
        }

        return Result(verticalOffset: offset, isScrollRequired: false)
    }
}

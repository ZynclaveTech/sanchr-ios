import SwiftUI

/// Stacks a quoted-reply card above a message and sizes the pair the way a
/// bubble should be sized.
///
/// A plain `VStack` cannot do this. The card has to span the bubble's width,
/// and the only way to say that in a stack is to let it claim all the width on
/// offer — which is also what tells the stack how wide to be. Every reply came
/// out at the maximum bubble width, whatever it said: a one-word "Yes" quoting
/// "Ok" was as wide as a full sentence. It also squeezed the message itself,
/// which then truncated rather than wrapped.
///
/// The two questions have to be answered in order. First how wide the bubble
/// wants to be — the wider of what the card and the message would each like,
/// capped — and only then how to fill it, which is where the card spans.
struct QuotedBubbleLayout: Layout {

    /// The narrowest a bubble carrying a quote may be, as a share of the
    /// widest it may be.
    ///
    /// Hugging the content alone leaves a reply like "Yes" quoting "Ok" about
    /// sixty points wide, where the quote is two truncated words in a sliver —
    /// it stops doing the one job a quote has, which is to show what is being
    /// answered. A message with no quote is left to hug, since there is
    /// nothing there to become unreadable.
    private static let quotedMinimumFraction: CGFloat = 0.45


    /// The width rule, separated from the layout so it can be tested without
    /// standing up a view hierarchy.
    ///
    /// - Parameters:
    ///   - naturalWidths: what each part would like if nothing constrained it
    ///     — the message's unwrapped line, the card's single line of quote.
    ///   - cap: the widest a bubble may be.
    ///   - carriesQuote: whether a quote card is one of the parts.
    static func resolvedWidth(
        naturalWidths: [CGFloat],
        cap: CGFloat,
        carriesQuote: Bool
    ) -> CGFloat {
        let natural = naturalWidths.max() ?? 0
        let floor = carriesQuote && cap.isFinite ? cap * quotedMinimumFraction : 0
        return min(cap, max(natural, floor))
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let cap = proposal.width ?? .infinity
        let width = Self.resolvedWidth(
            naturalWidths: subviews.map { $0.sizeThatFits(.unspecified).width },
            cap: cap,
            carriesQuote: subviews.count > 1
        )
        let height = subviews.reduce(into: 0.0) { total, subview in
            total += subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var y = bounds.minY
        for subview in subviews {
            let height = subview.sizeThatFits(
                ProposedViewSize(width: bounds.width, height: nil)
            ).height
            // Placed at the resolved width, not their own — this is what lets
            // the card span the bubble once the bubble's width is settled.
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                proposal: ProposedViewSize(width: bounds.width, height: height)
            )
            y += height
        }
    }
}

import SwiftUI
import SanchrShared

/// The reactions on a message.
///
/// Reactions could be chosen, were stored, were sent, and the cell dutifully
/// reconfigured itself when they changed — and nothing anywhere drew them. No
/// view in the app referenced `Message.reactions` at all, so picking one from
/// the context menu appeared to do nothing.
///
/// Follows Signal's `CVReactionCountsView`: a short pill on the bubble's lower
/// edge, one entry per distinct emoji, with a count once more than one person
/// has used it.
struct MessageReactionsPill: View {

    let reactions: [Message.MessageReaction]
    let isOutgoing: Bool
    /// Highlights the viewer's own reaction, so it is obvious which one is
    /// yours to remove.
    let localUserId: String?
    let onTap: (String) -> Void

    /// Signal's `CVReactionCountsView.height`.
    private static let height: CGFloat = 24

    /// Distinct emoji in the order they were first used, with counts.
    ///
    /// Ordered by first use rather than by count: a pill that reorders itself
    /// as reactions arrive makes the one you are reaching for move.
    static func grouped(_ reactions: [Message.MessageReaction]) -> [(emoji: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for reaction in reactions.sorted(by: { $0.timestamp < $1.timestamp }) {
            if counts[reaction.emoji] == nil { order.append(reaction.emoji) }
            counts[reaction.emoji, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    private func isMine(_ emoji: String) -> Bool {
        guard let localUserId else { return false }
        return reactions.contains { $0.emoji == emoji && $0.userId == localUserId }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.grouped(reactions), id: \.emoji) { entry in
                Button {
                    onTap(entry.emoji)
                } label: {
                    HStack(spacing: 3) {
                        Text(entry.emoji)
                            .font(.system(size: 13))
                        // A count of one is the pill itself; showing "1" on
                        // every reaction is noise on the common case.
                        if entry.count > 1 {
                            Text("\(entry.count)")
                                .font(SanchrTypography.font(size: .xxs, weight: .medium))
                                .foregroundColor(SanchrExportColors.textSecondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            isMine(entry.emoji)
                                ? SanchrColors.primary.opacity(0.22)
                                : Color.clear
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    entry.count > 1
                        ? "\(entry.emoji), \(entry.count) reactions"
                        : "\(entry.emoji), 1 reaction"
                )
                .accessibilityHint(isMine(entry.emoji) ? "Removes your reaction." : "Adds your reaction.")
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: Self.height)
        .background(
            Capsule()
                .fill(SanchrExportColors.surface)
                .overlay(Capsule().strokeBorder(SanchrExportColors.line, lineWidth: 1))
                .sanchrShadow(0.12, radius: 3, y: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

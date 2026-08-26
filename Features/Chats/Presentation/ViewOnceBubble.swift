import SanchrShared
import SwiftUI

/// Placeholder shown in the transcript in place of unopened view-once media.
///
/// View-once media previously rendered as an ordinary inline thumbnail, which
/// defeated the feature before the user ever tapped it: the content was visible
/// in the transcript indefinitely, and the "delete after viewing" step in the
/// gallery only removed something the recipient had already been shown.
///
/// Nothing is decoded here. The bubble knows the media's type and nothing else,
/// so the bytes stay encrypted on disk until the recipient deliberately opens it.
struct ViewOnceBubble: View {
    let attachment: Message.MediaAttachment
    let isVideo: Bool
    let isOutgoing: Bool
    /// True once the recipient opened and consumed it — the row is about to be
    /// replaced by a `.viewOnceConsumed` tombstone.
    let isConsumed: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var label: String {
        if isConsumed { return "Opened" }
        return isVideo ? "Video" : "Photo"
    }

    private var icon: String {
        if isConsumed { return "checkmark.circle" }
        return isVideo ? "video.badge.waveform" : "flame"
    }

    private var tint: Color {
        isConsumed ? SanchrExportColors.textSecondary : SanchrColors.primary
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(SanchrTypography.messageBubbleText)
                    .foregroundColor(
                        isConsumed ? SanchrExportColors.textSecondary : SanchrExportColors.textPrimary
                    )
                Text(isConsumed ? "No longer available" : "View once")
                    .font(.caption2)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer(minLength: 0)

            if !isConsumed {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(SanchrExportColors.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minWidth: 190, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    tint.opacity(isConsumed ? 0.18 : 0.35),
                    style: StrokeStyle(lineWidth: 1, dash: isConsumed ? [] : [4, 3])
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(colorScheme == .dark ? 0.10 : 0.06))
                )
        )
        .opacity(isConsumed ? 0.7 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isConsumed
                ? "\(isVideo ? "Video" : "Photo"), already opened and no longer available"
                : "\(isVideo ? "Video" : "Photo"), view once. Opens once, then is deleted."
        )
        .accessibilityAddTraits(isConsumed ? [] : .isButton)
    }
}

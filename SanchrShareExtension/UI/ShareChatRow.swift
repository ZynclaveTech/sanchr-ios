import SwiftUI
import SanchrShared

/// Single row in the share-extension chat picker. Mirrors the visual
/// vocabulary of the host app's chat list (avatar circle, title, last
/// message preview) but reads from the lightweight `ShareChatSummary`
/// projection instead of a full `Conversation`.
struct ShareChatRow: View {

    let summary: ShareChatSummary
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                selectionIndicator

                avatar

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(.body.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let preview = summary.lastMessagePreview, !preview.isEmpty {
                        Text(preview)
                            .font(.caption)
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isSelected ? SanchrColors.primary : Color(uiColor: .systemGray3),
                    lineWidth: 2
                )
                .background(
                    Circle().fill(isSelected ? SanchrColors.primary : .clear)
                )
                .frame(width: 24, height: 24)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }

    private var avatar: some View {
        Circle()
            .fill(Color(uiColor: .systemGray5))
            .frame(width: 44, height: 44)
            .overlay(
                Text(initials(for: summary.title))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textSecondary)
            )
    }

    private func initials(for title: String) -> String {
        let words = title
            .split(separator: " ", omittingEmptySubsequences: true)
            .prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }
}

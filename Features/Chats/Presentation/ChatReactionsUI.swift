import SwiftUI
import SanchrShared

// MARK: - Reaction Picker
// Extracted from ChatDetailView.swift on 2026-04-20 as part of god-file refactor.
// Visibility promoted from `private` to module-internal for cross-file access.

struct ReactionPickerView: View {
    let onSelect: (String) -> Void
    private let quickReactions = ["❤️", "👍", "😂", "😮", "😢", "🙏"]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(quickReactions, id: \.self) { emoji in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onSelect(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 28))
                        .frame(width: 44, height: 44)
                        .background(SanchrExportColors.surface)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(SanchrExportColors.background)
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 10)
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Reaction Pills

struct ReactionPillsView: View {
    let reactions: [Message.MessageReaction]
    let isOutgoing: Bool
    let onTapReaction: (String) -> Void

    /// Group reactions by emoji with count
    private var grouped: [(emoji: String, count: Int, userIds: [String])] {
        var dict: [String: [String]] = [:]
        for r in reactions {
            dict[r.emoji, default: []].append(r.userId)
        }
        return dict.map { (emoji: $0.key, count: $0.value.count, userIds: $0.value) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(grouped, id: \.emoji) { item in
                Button {
                    onTapReaction(item.emoji)
                } label: {
                    HStack(spacing: 3) {
                        Text(item.emoji)
                            .font(.system(size: 14))
                        if item.count > 1 {
                            Text("\(item.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(SanchrExportColors.textSecondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SanchrExportColors.surface)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(SanchrExportColors.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

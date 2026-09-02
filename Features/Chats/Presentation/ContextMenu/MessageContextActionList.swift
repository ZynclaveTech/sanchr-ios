import SwiftUI
import SanchrShared

/// The actions below the lifted message.
///
/// Deliberately not a `Menu` or a `.contextMenu`: this has to sit at a position
/// we choose, beneath a message we are also drawing, which is the whole reason
/// the native menu could not be used.
struct MessageContextActionList: View {

    let actions: [MessageContextAction]
    let isTrailingAligned: Bool
    /// Set when the group is taller than the screen — the menu gives way
    /// rather than pushing the message off the top.
    let scrolls: Bool
    let maxHeight: CGFloat
    let onSelect: (MessageContextAction) -> Void

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onSelect(action)
                } label: {
                    HStack(spacing: 12) {
                        Text(action.title)
                            .font(SanchrTypography.body)
                        Spacer(minLength: 16)
                        Image(systemName: action.systemImage)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 22)
                    }
                    .foregroundStyle(action.isDestructive ? Color.sanchrError : Color.primary)
                    .padding(.horizontal, 16)
                    .frame(height: MessageContextAction.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.title)

                if index < actions.count - 1 {
                    Divider().opacity(0.4).padding(.leading, 16)
                }
            }
        }
        .frame(width: 240)
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView { rows }
                    .frame(maxHeight: max(maxHeight, MessageContextAction.rowHeight * 3))
            } else {
                rows
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        }
        .sanchrShadow(0.18, radius: 16, y: 6)
        .fixedSize(horizontal: true, vertical: !scrolls)
        .accessibilityElement(children: .contain)
    }
}

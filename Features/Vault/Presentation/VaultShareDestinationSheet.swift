import SwiftUI
import SanchrShared

/// Two-row chooser presented when the user taps Share on a vault card.
/// Offers "Share in chat" and "Share outside Sanchr" with a privacy
/// disclosure under the external option.
///
/// Presented from `VaultView` when `shareState == .choosingDestination`.
/// Each row dispatches back to the view model to transition state:
/// `onShareInChat` → `.pickingConversation`, `onShareOutside` → kicks
/// off the coordinator download + `.externalSharing`.
struct VaultShareDestinationSheet: View {
    let item: VaultItem
    let onShareInChat: () -> Void
    let onShareOutside: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                row(
                    icon: "message.fill",
                    tint: SanchrColors.primary,
                    title: "Share in chat",
                    subtitle: "Send to a Sanchr conversation",
                    caveat: nil,
                    action: onShareInChat
                )

                row(
                    icon: "square.and.arrow.up",
                    tint: SanchrColors.accent,
                    title: "Share outside Sanchr",
                    subtitle: "Use the iOS share sheet",
                    // One-line disclosure. Once the user picks this row,
                    // Sanchr's E2EE guarantee ends at the temp file; the
                    // target app handles the bytes. Important to
                    // surface without being a modal.
                    caveat: "The file leaves Sanchr and is handled by the target app.",
                    action: onShareOutside
                )

                Spacer()
            }
            .padding(20)
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
            .background(SanchrExportColors.background.ignoresSafeArea())
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func row(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        caveat: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(
                        tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text(subtitle)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                    if let caveat {
                        Text(caveat)
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textTertiary)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SanchrExportColors.textTertiary)
            }
            .padding(16)
            .background(
                SanchrExportColors.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

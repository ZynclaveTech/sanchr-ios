import SwiftUI
import SanchrShared

/// Hero card at the top of the Privacy screen that toggles Sanchr Mode.
/// The two pills below the toggle describe the behaviors Sanchr Mode
/// enables (silent notifications, hidden previews). Gradient is
/// intentionally dark in both light and dark themes.
struct SanchrModeCard: View {
    @Binding var isOn: Bool
    var onToggleChanged: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(SanchrColors.accent)

                        Text("Sanchr Mode")
                            .font(SanchrTypography.cardTitle)
                            .foregroundColor(.white)
                    }

                    Text("Enhanced privacy with hidden previews and a more discreet interface.")
                        .font(SanchrTypography.caption)
                        .foregroundColor(.white.opacity(0.72))
                }

                Spacer()

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(SanchrColors.accent)
                    .onChange(of: isOn) { _, _ in
                        Task { await onToggleChanged() }
                    }
            }

            HStack(spacing: 12) {
                statPill(icon: "bell.slash.fill", title: "Silent Notifications")
                statPill(icon: "eye.slash.fill", title: "Hidden Previews")
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x111827), Color(hex: 0x0F172A)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func statPill(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.72))
            Text(title)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

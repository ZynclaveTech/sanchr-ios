import SwiftUI
import SanchrShared

struct SanchrModeCard: View {
    @Binding var isOn: Bool
    var onToggleChanged: (Bool) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                SettingsIconTile(systemName: "eye.slash", role: .accent)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sanchr Mode")
                        .font(SanchrTypography.cardTitle)
                        .foregroundColor(SanchrExportColors.textPrimary)

                    Text("Enhanced privacy with hidden previews and a more discreet interface.")
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(.sanchrPrimary)
                    .onChange(of: isOn) { _, newValue in
                        Task { await onToggleChanged(newValue) }
                    }
            }

            HStack(spacing: 12) {
                statPill(icon: "bell.slash", title: "Silent Notifications")
                statPill(icon: "eye.slash", title: "Hidden Previews")
            }
        }
        .padding(20)
        .settingsCard(cornerRadius: 26)
    }

    private func statPill(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(SanchrExportColors.textSecondary)
            Text(title)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrExportColors.textPrimary)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(SanchrExportColors.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

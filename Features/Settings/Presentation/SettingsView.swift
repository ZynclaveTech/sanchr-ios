import Kingfisher
import SwiftUI

struct SettingsView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = SettingsViewModel()

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                header
                profileCard
                sanchrModeCard
                settingsGroup(
                    title: "Account",
                    rows: [
                        AnySettingsRow(
                            icon: "key.fill",
                            tint: SanchrColors.primary,
                            background: Color(hex: 0xEEF2FF),
                            title: "Encryption Keys",
                            subtitle: "Manage & verify keys",
                            destination: AnyView(EncryptionKeysView())
                        ),
                        AnySettingsRow(
                            icon: "shield.fill",
                            tint: SanchrColors.accent,
                            background: Color(hex: 0xECFEFF),
                            title: "Security",
                            subtitle: "2FA, biometric & more",
                            destination: AnyView(SecurityView())
                        ),
                        AnySettingsRow(
                            icon: "lock.fill",
                            tint: Color(hex: 0x7C3AED),
                            background: Color(hex: 0xF5F3FF),
                            title: "Privacy",
                            subtitle: "Control who can see your info",
                            destination: AnyView(PrivacyView())
                        ),
                        AnySettingsRow(
                            icon: "lock.doc.fill",
                            tint: Color(hex: 0x2563EB),
                            background: Color(hex: 0xEFF6FF),
                            title: "Vault",
                            subtitle: "Secure media storage",
                            destination: AnyView(VaultView())
                        ),
                    ]
                )
                settingsGroup(
                    title: "Preferences",
                    rows: [
                        AnySettingsRow(
                            icon: "bell.fill",
                            tint: Color(hex: 0xCA8A04),
                            background: Color(hex: 0xFEFCE8),
                            title: "Notifications",
                            subtitle: "Activity & preferences",
                            destination: AnyView(NotificationsInboxView())
                        ),
                        AnySettingsRow(
                            icon: "paintpalette.fill",
                            tint: Color(hex: 0x4F46E5),
                            background: Color(hex: 0xEEF2FF),
                            title: "Appearance",
                            subtitle: themeSubtitle,
                            destination: AnyView(AppearanceView())
                        ),
                        AnySettingsRow(
                            icon: "bubble.left.fill",
                            tint: Color(hex: 0x16A34A),
                            background: Color(hex: 0xF0FDF4),
                            title: "Chats",
                            subtitle: "Chat style, backup & disappearing messages",
                            destination: AnyView(ChatSettingsView())
                        ),
                        AnySettingsRow(
                            icon: "externaldrive.fill",
                            tint: Color(hex: 0xDC2626),
                            background: Color(hex: 0xFEF2F2),
                            title: "Storage & Data",
                            subtitle: storageSubtitle,
                            destination: AnyView(StorageView())
                        ),
                    ]
                )
                settingsGroup(
                    title: "Support",
                    rows: [
                        AnySettingsRow(
                            icon: "questionmark.circle.fill",
                            tint: Color(hex: 0x6B7280),
                            background: Color(hex: 0xF3F4F6),
                            title: "Help Center",
                            subtitle: "Guides, FAQs & security tips",
                            destination: AnyView(HelpCenterView())
                        ),
                        AnySettingsRow(
                            icon: "envelope.fill",
                            tint: Color(hex: 0x6B7280),
                            background: Color(hex: 0xF3F4F6),
                            title: "Contact Us",
                            subtitle: "Reach the Sanchr team",
                            destination: AnyView(ContactUsView())
                        ),
                        AnySettingsRow(
                            icon: "doc.text.fill",
                            tint: Color(hex: 0x6B7280),
                            background: Color(hex: 0xF3F4F6),
                            title: "Terms & Privacy",
                            subtitle: "Policies and legal information",
                            destination: AnyView(PrivacyView())
                        ),
                    ]
                )

                if viewModel.vyncModeEnabled {
                    activatedCard
                }

                Text("Sanchr v\(viewModel.appVersion)")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textTertiary)
                    .padding(.top, 8)
            }
            .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .padding(.bottom, 24)
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .navigationBarHidden(true)
        .task {
            viewModel.loadProfile(from: container.sessionService)
            await viewModel.loadSettings(
                settingsDataSource: settingsDataSource,
                appLockManager: container.appLockManager,
                privacySettings: container.privacySettings
            )
            await viewModel.loadStorageUsage(settingsDataSource: settingsDataSource)
        }
    }

    private var header: some View {
        HStack {
            Color.clear
                .frame(width: 40, height: 40)

            Spacer()

            Text("Settings")
                .font(SanchrTypography.cardTitle)
                .foregroundColor(SanchrExportColors.textPrimary)

            Spacer()

            SanchrIconButton(systemName: "magnifyingglass") {}
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(SanchrExportColors.surface.ignoresSafeArea(edges: .top))
    }

    private var profileCard: some View {
        NavigationLink {
            ProfileView()
        } label: {
            HStack(spacing: 16) {
                avatar

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.displayName)
                        .font(SanchrTypography.cardTitle)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text(viewModel.phoneNumber)
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer()

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SanchrExportColors.surfaceMuted)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "qrcode")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.sanchrPrimary)
                    }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = URL(string: viewModel.avatarURL), !viewModel.avatarURL.isEmpty {
                    KFImage(url)
                        .resizable()
                        .placeholder { avatarPlaceholder }
                        .fade(duration: 0.2)
                        .scaledToFill()
                } else {
                    avatarPlaceholder
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())

            Circle()
                .fill(SanchrColors.accent)
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                }
                .offset(x: 1, y: 1)
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color.sanchrPrimary.opacity(0.18))
            .overlay {
                Text(viewModel.displayName.prefix(1).uppercased())
                    .font(SanchrTypography.sectionHeader)
                    .foregroundColor(.sanchrPrimary)
            }
    }

    private var sanchrModeCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [SanchrColors.primaryDark, Color(hex: 0x0F172A)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sanchr Mode")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text("Enhanced privacy & security")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .tint(.sanchrPrimary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { viewModel.vyncModeEnabled },
            set: { newValue in
                Task {
                    if newValue != viewModel.vyncModeEnabled {
                        await viewModel.toggleVyncMode(settingsDataSource: settingsDataSource)
                    }
                }
            }
        )
    }

    private var activatedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sanchr Mode Activated")
                .font(SanchrTypography.sectionHeader)
                .foregroundColor(SanchrExportColors.textPrimary)

            Text("Private mode hides previews, softens presence signals, and reduces exposed metadata throughout the app.")
                .font(SanchrTypography.body)
                .foregroundColor(SanchrExportColors.textSecondary)

            HStack(spacing: 10) {
                activatedPill(icon: "bell.slash.fill", title: "Hidden Notifications")
                activatedPill(icon: "eye.slash.fill", title: "Reduced Presence")
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xEEF2FF), Color(hex: 0xF5F3FF)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(hex: 0xDDE6FF), lineWidth: 1)
        }
    }

    private func activatedPill(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(SanchrTypography.captionSmall)
        }
        .foregroundColor(SanchrExportColors.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(SanchrExportColors.surface)
        .clipShape(Capsule())
    }

    private func settingsGroup(title: String, rows: [AnySettingsRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(SanchrTypography.sectionLabel)
                .tracking(1.2)
                .foregroundColor(SanchrExportColors.textSecondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    row

                    if index < rows.count - 1 {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var themeSubtitle: String {
        switch viewModel.theme.lowercased() {
        case "dark":
            return "Dark"
        case "light":
            return "Light"
        default:
            return "Light"
        }
    }

    private var storageSubtitle: String {
        let total = viewModel.totalBytes > 0 ? viewModel.formattedBytes(viewModel.totalBytes) : "Manage downloads"
        return total
    }
}

private struct AnySettingsRow: View {
    let icon: String
    let tint: Color
    let background: Color
    let title: String
    let subtitle: String
    let destination: AnyView

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SanchrExportColors.surfaceMuted)
                    .frame(width: 42, height: 42)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.sanchrPrimary)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text(subtitle)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

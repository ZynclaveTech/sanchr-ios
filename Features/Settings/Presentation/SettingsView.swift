import Kingfisher
import SwiftUI
import SanchrShared

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = SettingsViewModel()
    @State private var settingsSearchText = ""
    @AppStorage("sanchr.themeMode") private var storedThemeMode = SanchrTheme.Mode.system.rawValue

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                // The home tabs' search field, not the system one: same font, fill and height.
                SanchrSearchField(placeholder: "Search settings...", text: $settingsSearchText) { EmptyView() }
                profileCard
                sanchrModeCard
                filteredSettingsGroup(
                    title: "Account",
                    rows: [
                        AnySettingsRow(
                            icon: "key",
                            title: "Encryption Keys",
                            subtitle: "Manage & verify keys",
                            destination: AnyView(EncryptionKeysView())
                        ),
                        AnySettingsRow(
                            icon: "shield",
                            title: "Security",
                            subtitle: "2FA, biometric & more",
                            destination: AnyView(SecurityView())
                        ),
                        AnySettingsRow(
                            icon: "lock",
                            title: "Privacy",
                            subtitle: "Control who can see your info",
                            destination: AnyView(PrivacyView())
                        ),
                        AnySettingsRow(
                            icon: "lock.doc",
                            title: "Vault",
                            subtitle: "Secure media storage",
                            destination: AnyView(VaultView())
                        ),
                        AnySettingsRow(
                            icon: "icloud.and.arrow.up",
                            title: "Backup & Recovery",
                            subtitle: backupSubtitle,
                            destination: AnyView(BackupView())
                        ),
                    ]
                )
                filteredSettingsGroup(
                    title: "Preferences",
                    rows: [
                        AnySettingsRow(
                            icon: "bell",
                            title: "Notifications",
                            subtitle: "Activity & preferences",
                            destination: AnyView(NotificationsInboxView())
                        ),
                        AnySettingsRow(
                            icon: "paintpalette",
                            title: "Appearance",
                            subtitle: themeSubtitle,
                            destination: AnyView(AppearanceView())
                        ),
                        AnySettingsRow(
                            icon: "bubble.left",
                            title: "Chats",
                            subtitle: "Chat style, backup & disappearing messages",
                            destination: AnyView(ChatSettingsView())
                        ),
                        AnySettingsRow(
                            icon: "externaldrive",
                            title: "Storage & Data",
                            subtitle: storageSubtitle,
                            destination: AnyView(StorageView())
                        ),
                    ]
                )
                filteredSettingsGroup(
                    title: "Support",
                    rows: [
                        AnySettingsRow(
                            icon: "questionmark.circle",
                            title: "Help Center",
                            subtitle: "Guides, FAQs & security tips",
                            destination: AnyView(HelpCenterView())
                        ),
                        AnySettingsRow(
                            icon: "envelope",
                            title: "Contact Us",
                            subtitle: "Reach the Sanchr team",
                            destination: AnyView(ContactUsView())
                        ),
                        AnySettingsRow(
                            icon: "doc.text",
                            title: "Terms & Privacy",
                            subtitle: "Privacy Policy and Terms of Service",
                            destination: AnyView(LegalView())
                        ),
                    ]
                )

                if viewModel.sanchrModeEnabled {
                    activatedCard
                }

                Text("Sanchr v\(viewModel.appVersion)")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textTertiary)
                    .padding(.top, 8)

                SettingsErrorLabel(message: viewModel.errorMessage)
            }
            .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .padding(.bottom, 24)
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .sanchrInteractivePopEnabled()
        .task {
            viewModel.loadProfile(from: container.sessionService)
            await viewModel.loadSettings(
                settingsDataSource: settingsDataSource,
                privacySettings: container.privacySettings,
                appLockManager: container.appLockManager
            )
            await viewModel.loadStorageUsage()
        }
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
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.sanchrPrimary)
                    }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .settingsCard(cornerRadius: 22)
            .contentShape(Rectangle())
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
            SettingsIconTile(systemName: "eye.slash", role: .accent)

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
        .settingsCard()
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { viewModel.sanchrModeEnabled },
            set: { newValue in
                Task {
                    await viewModel.setSanchrMode(enabled: newValue, settingsDataSource: settingsDataSource)
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
                activatedPill(icon: "bell.slash", title: "Hidden Notifications")
                activatedPill(icon: "eye.slash", title: "Reduced Presence")
            }
        }
        .padding(20)
        .settingsCard(cornerRadius: 24)
    }

    private func activatedPill(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(SanchrTypography.captionSmall)
        }
        .foregroundColor(SanchrExportColors.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .sanchrFieldBackground(colorScheme)
        .clipShape(Capsule())
    }

    private func matchesSearch(_ title: String) -> Bool {
        settingsSearchText.isEmpty || title.localizedCaseInsensitiveContains(settingsSearchText)
    }

    @ViewBuilder
    private func filteredSettingsGroup(title: String, rows: [AnySettingsRow]) -> some View {
        let filtered = rows.filter { matchesSearch($0.title) }
        if !filtered.isEmpty {
            settingsGroup(title: title, rows: filtered)
        }
    }

    private func settingsGroup(title: String, rows: [AnySettingsRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionTitle(title: title)
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
            .settingsCard(cornerRadius: 22)
        }
    }

    /// The theme the app actually applies is the stored one that
    /// SanchrApp and AppearanceView share; the server's `theme` field
    /// defaulted to "light" and the row said Light no matter what.
    private var themeSubtitle: String {
        switch SanchrTheme.Mode(rawValue: storedThemeMode) ?? .system {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "System"
        }
    }

    private var storageSubtitle: String {
        let total = viewModel.totalBytes > 0 ? viewModel.formattedBytes(viewModel.totalBytes) : "Manage downloads"
        return total
    }

    private var backupSubtitle: String {
        let coordinator = container.backupCoordinator
        guard coordinator.isEnabled else { return "Off" }
        guard let lastBackupAt = coordinator.configuration?.lastBackupAt else {
            return "Enabled · No backups yet"
        }
        let interval = Date().timeIntervalSince(lastBackupAt)
        if interval < 3600 {
            let mins = max(1, Int(interval / 60))
            return "Last backed up \(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "Last backed up \(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "Last backed up \(days)d ago"
        }
    }
}

private struct AnySettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let destination: AnyView

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 14) {
                SettingsIconTile(systemName: icon)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text(subtitle)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer()

                SettingsChevron()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Title plus the ground every settings screen shares: the same
    /// `background` the Chats, Calls and Contacts tabs paint, so Settings
    /// no longer looks like a different app. Subscreens used to pick their
    /// own (grouped, plain, or none), so pushing between them changed colour.
    func sanchrSettingsSubscreenNavigation(title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .background(SanchrExportColors.background.ignoresSafeArea())
    }
}

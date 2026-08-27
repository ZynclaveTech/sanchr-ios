import SwiftUI
import UIKit
import SanchrShared

/// Chat-specific settings screen.
/// Matches Figma: chat-settings-main.
/// Syncs chat/privacy/storage settings to the backend where supported.
struct ChatSettingsView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = SettingsViewModel()
    @AppStorage("sanchr.enterSendsMessage") private var enterSendsMessage = true
    @AppStorage("sanchr.linkPreviews") private var linkPreviews = true
    @AppStorage("sanchr.mediaAutoSave") private var mediaAutoSave = false
    @AppStorage(DefaultDisappearingTimer.storageKey) private var defaultDisappearingTimer = "off"
    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    private let autoDownloadOptions = [
        ("All media", "all"),
        ("Photos only", "photos"),
        ("No media", "none"),
    ]

    private let disappearingTimerOptions = [
        // Kept in step with the per-conversation options in
        // `DisappearingMessagesView`: the previous list offered defaults
        // (5 seconds, 30 seconds, 1 minute) that no conversation could
        // actually be set to.
        ("Off", "off"),
        ("5 minutes", "5m"),
        ("1 hour", "1h"),
        ("24 hours", "24h"),
        ("7 days", "7d"),
        ("30 days", "30d"),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                mediaDownloadSection
                encryptionSection
                chatBehaviourSection
                backupSection
                disappearingSection
            }
            .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .padding(.bottom, 28)
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .sanchrSettingsSubscreenNavigation(title: "Chat Settings")
        .task {
            await viewModel.loadSettings(
                settingsDataSource: settingsDataSource,
                privacySettings: container.privacySettings
            )
            container.backupCoordinator.reload()
        }
    }

    private var mediaDownloadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Media Auto-Download")

            VStack(spacing: 12) {
                optionRow(
                    icon: "wifi",
                    title: "When using Wi-Fi",
                    value: viewModel.autoDownloadWifi
                ) { option in
                    viewModel.autoDownloadWifi = option
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                optionRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "When using mobile data",
                    value: viewModel.autoDownloadMobile
                ) { option in
                    viewModel.autoDownloadMobile = option
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                // No "When roaming" row: iOS exposes no supported way to detect
                // roaming — CTCarrier was deprecated in iOS 16 and reports
                // placeholder values — so the choice could never be honoured.
                // Roaming is cellular, and the mobile-data setting governs it.
            }
        }
    }

    private var encryptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Encryption & Security")

            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    SettingsIconTile(systemName: "shield", role: .accent, size: 44, iconSize: 18)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("End-to-End Encryption")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text("All your messages and calls are secured. Only you and the recipient can read them.")
                            .font(SanchrTypography.caption)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                }
                .padding(18)
                .settingsCard()

                NavigationLink {
                    EncryptionKeysView()
                } label: {
                    chevronRow(
                        icon: "qrcode",
                        title: "Security Code",
                        subtitle: "Verify encryption keys"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chatBehaviourSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Chat Behaviour")

            VStack(spacing: 0) {
                toggleRow(
                    icon: "paperplane",
                    title: "Enter Sends Message",
                    subtitle: "Press return to send instantly",
                    isOn: $enterSendsMessage
                ) {}

                Divider()
                    .padding(.leading, 56)

                toggleRow(
                    icon: "link",
                    title: "Link Previews",
                    subtitle: "Preview URLs inside chats",
                    isOn: $linkPreviews
                ) {}

                Divider()
                    .padding(.leading, 56)

                toggleRow(
                    icon: "square.and.arrow.down",
                    title: "Auto-save Received Media",
                    subtitle: "Keep photos and videos offline",
                    isOn: $mediaAutoSave
                ) {}
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Backup")

            NavigationLink { BackupView() } label: {
                chevronRow(
                    icon: "icloud.and.arrow.up",
                    title: "Backup & Recovery",
                    subtitle: backupSubtitle
                )
            }
            .buttonStyle(.plain)
        }
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

    private var disappearingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Disappearing Messages")

            Menu {
                ForEach(disappearingTimerOptions, id: \.1) { name, value in
                    Button(name) {
                        defaultDisappearingTimer = value
                    }
                }
            } label: {
                chevronRow(
                    icon: "timer",
                    title: "Default Timer",
                    subtitle: disappearingTimerOptions.first(where: { $0.1 == defaultDisappearingTimer })?.0 ?? "Off"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        SettingsSectionTitle(title: title)
    }

    private func toggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onChange: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.sanchrPrimary)
                .onChange(of: isOn.wrappedValue) { _, _ in
                    onChange()
                }
        }
        .padding(.vertical, 12)
    }

    private func optionRow(
        icon: String,
        title: String,
        value: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(autoDownloadOptions, id: \.1) { name, option in
                Button(name) {
                    onSelect(option)
                }
            }
        } label: {
            chevronRow(
                icon: icon,
                title: title,
                subtitle: autoDownloadOptions.first(where: { $0.1 == value })?.0 ?? "Default"
            )
        }
        .buttonStyle(.plain)
    }

    private func chevronRow(
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SanchrExportColors.textTertiary)
        }
        .padding(16)
        .settingsCard()
    }

    private func iconTile(systemName: String) -> some View {
        SettingsIconTile(systemName: systemName)
    }

}

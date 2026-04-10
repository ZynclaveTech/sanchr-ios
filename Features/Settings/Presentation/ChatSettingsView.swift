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
    @AppStorage("sanchr.defaultDisappearingTimer") private var defaultDisappearingTimer = "off"
    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    private let autoDownloadOptions = [
        ("All media", "all"),
        ("Photos only", "photos"),
        ("No media", "none"),
    ]

    private let disappearingTimerOptions = [
        ("Off", "off"),
        ("5 seconds", "5s"),
        ("30 seconds", "30s"),
        ("1 minute", "1m"),
        ("5 minutes", "5m"),
        ("1 hour", "1h"),
        ("24 hours", "24h"),
        ("7 days", "7d"),
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
                    tint: Color(hex: 0x16A34A),
                    background: Color(hex: 0xDCFCE7),
                    title: "When using Wi-Fi",
                    value: viewModel.autoDownloadWifi
                ) { option in
                    viewModel.autoDownloadWifi = option
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                optionRow(
                    icon: "antenna.radiowaves.left.and.right",
                    tint: Color(hex: 0x2563EB),
                    background: Color(hex: 0xDBEAFE),
                    title: "When using mobile data",
                    value: viewModel.autoDownloadMobile
                ) { option in
                    viewModel.autoDownloadMobile = option
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                optionRow(
                    icon: "airplane",
                    tint: Color(hex: 0xEA580C),
                    background: Color(hex: 0xFFEDD5),
                    title: "When roaming",
                    value: viewModel.autoDownloadRoaming
                ) { option in
                    viewModel.autoDownloadRoaming = option
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }
            }
        }
    }

    private var encryptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Encryption & Security")

            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [SanchrColors.primary, Color(hex: 0x4C1D95)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 112)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 44, height: 44)
                                .overlay {
                                    Image(systemName: "shield.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white)
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("End-to-End Encryption")
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(.white)
                                Text("All your messages and calls are secured. Only you and the recipient can read them.")
                                    .font(SanchrTypography.caption)
                                    .foregroundColor(.white.opacity(0.86))
                            }
                        }
                        .padding(.horizontal, 18)
                    }

                NavigationLink {
                    EncryptionKeysView()
                } label: {
                    chevronRow(
                        icon: "qrcode",
                        tint: SanchrColors.accent,
                        background: Color(hex: 0xECFEFF),
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
                    icon: "paperplane.fill",
                    tint: Color(hex: 0x7C3AED),
                    background: Color(hex: 0xF3E8FF),
                    title: "Enter Sends Message",
                    subtitle: "Press return to send instantly",
                    isOn: $enterSendsMessage
                ) {}

                Divider()
                    .padding(.leading, 56)

                toggleRow(
                    icon: "link",
                    tint: Color(hex: 0xCA8A04),
                    background: Color(hex: 0xFEF3C7),
                    title: "Link Previews",
                    subtitle: "Preview URLs inside chats",
                    isOn: $linkPreviews
                ) {}

                Divider()
                    .padding(.leading, 56)

                toggleRow(
                    icon: "square.and.arrow.down.fill",
                    tint: Color(hex: 0x16A34A),
                    background: Color(hex: 0xDCFCE7),
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
                    icon: "icloud.and.arrow.up.fill",
                    tint: SanchrColors.primary,
                    background: Color(hex: 0xEEF2FF),
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
                    tint: Color(hex: 0xEA580C),
                    background: Color(hex: 0xFFEDD5),
                    title: "Default Timer",
                    subtitle: disappearingTimerOptions.first(where: { $0.1 == defaultDisappearingTimer })?.0 ?? "Off"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(SanchrTypography.sectionLabel)
            .tracking(1.2)
            .foregroundColor(SanchrExportColors.textSecondary)
    }

    private func toggleRow(
        icon: String,
        tint: Color,
        background: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onChange: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon, tint: tint, background: background)

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
        tint: Color,
        background: Color,
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
                tint: tint,
                background: background,
                title: title,
                subtitle: autoDownloadOptions.first(where: { $0.1 == value })?.0 ?? "Default"
            )
        }
        .buttonStyle(.plain)
    }

    private func chevronRow(
        icon: String,
        tint: Color,
        background: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon, tint: tint, background: background)

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
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SanchrExportColors.textTertiary)
        }
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func iconTile(systemName: String, tint: Color, background: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(background)
            .frame(width: 42, height: 42)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(tint)
            }
    }

}

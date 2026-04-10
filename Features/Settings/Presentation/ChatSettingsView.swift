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
    @State private var showingRecoveryKeySheet = false
    @State private var revealedRecoveryKey: String?
    @State private var showingRevealedRecoveryKey = false
    @State private var showingRestoreSheet = false
    @State private var restoreRecoveryKey = ""

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
        .sheet(isPresented: $showingRecoveryKeySheet) {
            BackupRecoveryKeySheet(
                recoveryKey: container.backupCoordinator.pendingRecoveryKey ?? "",
                onConfirm: {
                    Task {
                        await container.backupCoordinator.confirmPendingRecoveryKey()
                        showingRecoveryKeySheet = false
                    }
                },
                onCancel: {
                    container.backupCoordinator.cancelPendingRecoveryKey()
                    showingRecoveryKeySheet = false
                }
            )
        }
        .sheet(isPresented: $showingRestoreSheet) {
            BackupRestoreSheet(
                recoveryKey: $restoreRecoveryKey,
                isProcessing: container.backupCoordinator.isProcessing,
                onRestore: {
                    let providedKey = restoreRecoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await container.backupCoordinator.restoreLatestBackup(
                            with: providedKey.isEmpty ? nil : providedKey
                        )
                        showingRestoreSheet = false
                    }
                },
                onCancel: {
                    showingRestoreSheet = false
                }
            )
        }
        .alert("Recovery Key", isPresented: $showingRevealedRecoveryKey) {
            Button("Copy") {
                UIPasteboard.general.string = revealedRecoveryKey
            }
            Button("Close", role: .cancel) {}
        } message: {
            Text(revealedRecoveryKey ?? "")
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
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                }
            }
        }
    }

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Backup")

            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    iconTile(systemName: "icloud.and.arrow.up.fill", tint: SanchrColors.primary, background: Color(hex: 0xEEF2FF))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Chat Backup")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text(container.backupCoordinator.isEnabled ? "Encrypted backup is active" : "Protect your chat history with an encrypted backup")
                            .font(SanchrTypography.caption)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }

                    Spacer()

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { container.backupCoordinator.isEnabled },
                            set: { enabled in
                                if enabled {
                                    container.backupCoordinator.prepareEnableBackups()
                                    showingRecoveryKeySheet = true
                                } else {
                                    container.backupCoordinator.disableBackups()
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .tint(.sanchrPrimary)
                }
                .padding(16)
                .background(SanchrExportColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                }

                if container.backupCoordinator.isEnabled {
                    VStack(spacing: 0) {
                        infoRow(title: "Last backup", value: container.backupCoordinator.configuration?.lastBackupAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")

                        Divider()
                            .padding(.leading, 18)

                        backupAction(title: "Back Up Now") {
                            Task {
                                do {
                                    try await container.backupCoordinator.backupNow()
                                } catch {
                                    container.backupCoordinator.reportError(error)
                                }
                            }
                        }

                        Divider()
                            .padding(.leading, 18)

                        backupAction(title: "Reveal Recovery Key") {
                            Task {
                                do {
                                    revealedRecoveryKey = try await container.backupCoordinator.revealRecoveryKey()
                                    showingRevealedRecoveryKey = true
                                } catch {
                                    container.backupCoordinator.reportError(error)
                                }
                            }
                        }

                        Divider()
                            .padding(.leading, 18)

                        backupAction(title: "Rotate Recovery Key") {
                            container.backupCoordinator.rotateRecoveryKey()
                            showingRecoveryKeySheet = true
                        }

                        Divider()
                            .padding(.leading, 18)

                        backupAction(title: "Delete Remote Backups", role: .destructive) {
                            Task {
                                await container.backupCoordinator.deleteRemoteBackups()
                            }
                        }
                    }
                    .background(SanchrExportColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                    }
                }

                Button {
                    restoreRecoveryKey = ""
                    showingRestoreSheet = true
                } label: {
                    chevronRow(
                        icon: "arrow.clockwise.circle.fill",
                        tint: Color(hex: 0x06B6D4),
                        background: Color(hex: 0xECFEFF),
                        title: "Restore from Backup",
                        subtitle: "Bring encrypted history to this device"
                    )
                }
                .buttonStyle(.plain)
                .disabled(container.backupCoordinator.isProcessing)

                if let errorMessage = container.backupCoordinator.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)
            Spacer()
            Text(value)
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func backupAction(title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(role == .destructive ? .sanchrError : SanchrExportColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
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

private struct BackupRestoreSheet: View {
    @Binding var recoveryKey: String
    let isProcessing: Bool
    let onRestore: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: SanchrSpacing.lg) {
                Text("Restore your encrypted chat history after sign-in using your recovery key. If this device already stores the key, you can leave the field blank.")
                    .font(SanchrTypography.body)

                TextField("Recovery key", text: $recoveryKey, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.md))

                Button("Restore Latest Backup", action: onRestore)
                    .buttonStyle(.borderedProminent)
                    .tint(.sanchrPrimary)
                    .disabled(isProcessing)
                    .frame(maxWidth: .infinity, alignment: .center)

                Button("Cancel", role: .cancel, action: onCancel)
                    .frame(maxWidth: .infinity, alignment: .center)

                Spacer()
            }
            .padding(SanchrSpacing.lg)
            .navigationTitle("Restore Backup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct BackupRecoveryKeySheet: View {
    @Environment(\.colorScheme) private var colorScheme
    let recoveryKey: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: SanchrSpacing.lg) {
                Text("Save this recovery key somewhere secure. You will need it to restore encrypted backups on a new device.")
                    .font(SanchrTypography.body)

                Text(recoveryKey)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sanchrSurface(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.md))

                Button("I saved this key", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.sanchrPrimary)
                    .frame(maxWidth: .infinity, alignment: .center)

                Button("Not now", role: .cancel, action: onCancel)
                    .frame(maxWidth: .infinity, alignment: .center)

                Spacer()
            }
            .padding(SanchrSpacing.lg)
            .navigationTitle("Recovery Key")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

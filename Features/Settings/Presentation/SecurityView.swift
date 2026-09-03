import LocalAuthentication
import SwiftUI
import SanchrShared

/// Security settings screen.
/// Matches Figma: security-screen.
/// Syncs screen lock, biometric, screenshot protection, and Sanchr Mode to backend.
struct SecurityView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = SettingsViewModel()
    @State private var showDeleteAccount = false

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    private let screenLockTimeouts: [(String, Int32)] = [
        ("Immediately", 0),
        ("30 seconds", 30),
        ("1 minute", 60),
        ("5 minutes", 300),
        ("15 minutes", 900),
        ("1 hour", 3600),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                sanchrModeCard
                featureSection
                privacySection
                accountSection

                SettingsErrorLabel(message: viewModel.errorMessage)
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.bottom, 28)
        }
        .sanchrSettingsSubscreenNavigation(title: "Security")
        .sheet(isPresented: $showDeleteAccount) {
            DeleteAccountConfirmationSheet()
        }
        .task {
            await viewModel.loadSettings(
                settingsDataSource: settingsDataSource,
                privacySettings: container.privacySettings,
                appLockManager: container.appLockManager
            )
        }
    }

    private var sanchrModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                SettingsIconTile(systemName: "eye.slash", role: .accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sanchr Mode")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text("Maximum privacy")
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $viewModel.sanchrModeEnabled)
                    .labelsHidden()
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.sanchrModeEnabled) { _, newValue in
                        Task {
                            await viewModel.setSanchrMode(enabled: newValue, settingsDataSource: settingsDataSource)
                        }
                    }
            }

            Text("Hide previews, detect screenshots after capture, and shield content during screen recording or mirroring.")
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrExportColors.textSecondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.sanchrModeEnabled ? Color.sanchrSuccess : SanchrExportColors.textTertiary)
                    .frame(width: 8, height: 8)
                Text(viewModel.sanchrModeEnabled ? "Currently enabled" : "Currently disabled")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(viewModel.sanchrModeEnabled ? .sanchrSuccess : SanchrExportColors.textSecondary)
            }
        }
        .padding(20)
        .settingsCard(cornerRadius: 26)
    }

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Security Features")

            NavigationLink {
                EncryptionKeysView()
            } label: {
                featureRow(
                    icon: "lock",
                    title: "End-to-End Encryption",
                    subtitle: "All messages secured",
                    showsStatusDot: true
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink {
                EncryptionKeysView()
            } label: {
                featureRow(
                    icon: "qrcode",
                    title: "Security Code Verification",
                    subtitle: "Verify contacts and device keys"
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink {
                VaultView()
            } label: {
                featureRow(
                    icon: "lock.doc",
                    title: "Vault Messages",
                    subtitle: "Self-destructing media and secure storage"
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink {
                RegistrationLockView()
            } label: {
                featureRow(
                    icon: "lock.shield",
                    title: "Registration Lock",
                    subtitle: viewModel.registrationLockEnabled ? "PIN protection enabled" : "Protect account re-registration",
                    showsStatusDot: viewModel.registrationLockEnabled
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                stackedToggleRow(
                    icon: "faceid",
                    title: "Biometric Lock",
                    subtitle: viewModel.biometricLock ? "App lock enabled" : "Require Face ID or Touch ID",
                    isOn: $viewModel.biometricLock
                ) { newValue in
                    container.appLockManager.biometricLockEnabled = newValue
                    if newValue {
                        // If no timeout has ever been configured, seed a sensible default
                        // (60 s) so biometric lock doesn't fire on every single app switch.
                        if container.appLockManager.screenLockTimeout == 0 {
                            viewModel.screenLockTimeout = 60
                            container.appLockManager.screenLockTimeout = 60
                        }
                        authenticateBiometric()
                    } else {
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
                }

                Divider()
                    .padding(.leading, 56)

                let lockActive = viewModel.biometricLock || viewModel.screenLockEnabled
                HStack(spacing: 14) {
                    iconTile(systemName: "lock.rectangle")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Screen Lock Timeout")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(
                                lockActive
                                    ? SanchrExportColors.textPrimary
                                    : SanchrExportColors.textSecondary
                            )
                        Text(lockActive ? timeoutLabel(viewModel.screenLockTimeout) : "Enable a lock above first")
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }

                    Spacer()

                    Menu {
                        ForEach(screenLockTimeouts, id: \.1) { label, value in
                            Button(label) {
                                viewModel.screenLockTimeout = value
                                container.appLockManager.screenLockTimeout = value
                                // Only flip screenLockEnabled on if biometric isn't
                                // already handling the lock — avoids a silent state change.
                                if !viewModel.biometricLock {
                                    viewModel.screenLockEnabled = true
                                    container.appLockManager.screenLockEnabled = true
                                }
                                viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(
                                lockActive
                                    ? SanchrExportColors.textTertiary
                                    : SanchrExportColors.textTertiary.opacity(0.4)
                            )
                        .contentShape(Rectangle())
                    }
                    .disabled(!lockActive)
                }
                .padding(.vertical, 12)
                .opacity(lockActive ? 1 : 0.5)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .settingsCard(cornerRadius: 24)
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Privacy Settings")

            VStack(spacing: 0) {
                stackedToggleRow(
                    icon: "checkmark.message",
                    title: "Read Receipts",
                    subtitle: "Show when you've read messages",
                    isOn: $viewModel.readReceipts
                ) { _ in
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                Divider()
                    .padding(.leading, 56)

                stackedToggleRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Online Status",
                    subtitle: "Let others see when you're active",
                    isOn: $viewModel.onlineStatusVisible
                ) { _ in
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                Divider()
                    .padding(.leading, 56)

                stackedToggleRow(
                    icon: "camera.viewfinder",
                    title: "Screenshot Protection",
                    subtitle: "Detect screenshots and hide content during screen recording or mirroring",
                    isOn: $viewModel.screenshotProtection
                ) { newValue in
                    container.appLockManager.screenshotProtectionEnabled = newValue
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .settingsCard(cornerRadius: 24)
        }
    }

    /// Real device count from the server. Previously this row was hardcoded to
    /// "1 device connected", so a user with several linked devices — or one whose
    /// account had been added to a device they did not recognise — was told
    /// everything was normal.
    @State private var activeDeviceCount: Int?
    @State private var activeSessionsFailed = false

    private var activeSessionsSubtitle: String {
        if let activeDeviceCount {
            return activeDeviceCount == 1
                ? "1 device connected"
                : "\(activeDeviceCount) devices connected"
        }
        return activeSessionsFailed ? "Unavailable" : "Checking…"
    }

    private func loadActiveSessionCount() async {
        guard activeDeviceCount == nil, !activeSessionsFailed else { return }
        guard let userId = container.sessionService.currentUserId else {
            activeSessionsFailed = true
            return
        }
        do {
            activeDeviceCount = try await container.signalKeyManager.registeredDeviceCount(
                userId: userId)
        } catch {
            // Say so rather than substituting a plausible number.
            activeSessionsFailed = true
            SanchrLogger.sync.error(
                "Active session count unavailable: \(error.localizedDescription)")
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Account")

            featureRow(
                icon: "desktopcomputer",
                title: "Active Sessions",
                subtitle: activeSessionsSubtitle
            )
            .task { await loadActiveSessionCount() }

            Button {
                showDeleteAccount = true
            } label: {
                featureRow(
                    icon: "trash",
                    title: "Delete Account",
                    subtitle: "Permanently erase your account and data",
                    role: .destructive
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        SettingsSectionTitle(title: title)
    }

    private func featureRow(
        icon: String,
        title: String,
        subtitle: String,
        showsStatusDot: Bool = false,
        role: SettingsIconRole = .neutral
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon, role: role)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            HStack(spacing: 8) {
                if showsStatusDot {
                    Circle()
                        .fill(Color.sanchrSuccess)
                        .frame(width: 8, height: 8)
                }

                Image(systemName: "chevron.right")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
            }
        }
        .padding(16)
        .settingsCard()
    }

    private func stackedToggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onChange: @escaping (Bool) -> Void
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
                .onChange(of: isOn.wrappedValue) { _, newValue in
                    onChange(newValue)
                }
        }
        .padding(.vertical, 12)
    }

    private func iconTile(systemName: String, role: SettingsIconRole = .neutral) -> some View {
        SettingsIconTile(systemName: systemName, role: role)
    }

    private func timeoutLabel(_ timeout: Int32) -> String {
        screenLockTimeouts.first(where: { $0.1 == timeout })?.0 ?? "Immediately"
    }

    private func authenticateBiometric() {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        else {
            viewModel.biometricLock = false
            viewModel.errorMessage = "Biometric authentication is not available on this device."
            return
        }

        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Enable biometric lock for Sanchr"
                )
                if success {
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                } else {
                    viewModel.biometricLock = false
                }
            } catch {
                viewModel.biometricLock = false
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

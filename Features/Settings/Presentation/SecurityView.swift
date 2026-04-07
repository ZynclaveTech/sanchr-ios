import LocalAuthentication
import SwiftUI
import SanchrShared

/// Security settings screen.
/// Matches Figma: security-screen.
/// Syncs screen lock, biometric, screenshot protection, and Sanchr Mode to backend.
struct SecurityView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = SettingsViewModel()
    @State private var showChangePassword = false
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
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.bottom, 28)
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .sanchrSettingsSubscreenNavigation(title: "Security")
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet()
        }
        .sheet(isPresented: $showDeleteAccount) {
            DeleteAccountConfirmationSheet()
        }
        .task {
            await viewModel.loadSettings(
                settingsDataSource: settingsDataSource,
                appLockManager: container.appLockManager
            )
        }
    }

    private var sanchrModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                iconTile(systemName: "eye.slash.fill", tint: SanchrColors.accent, background: Color.white.opacity(0.12))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sanchr Mode")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(.white)
                    Text("Maximum privacy")
                        .font(SanchrTypography.caption)
                        .foregroundColor(.white.opacity(0.72))
                }

                Spacer()

                Toggle("", isOn: $viewModel.vyncModeEnabled)
                    .labelsHidden()
                    .tint(SanchrColors.accent)
                    .onChange(of: viewModel.vyncModeEnabled) { _, _ in
                        Task {
                            await viewModel.toggleVyncMode(settingsDataSource: settingsDataSource)
                        }
                    }
            }

            Text("Hide previews, disable screenshots, and switch to a more discreet security posture.")
                .font(SanchrTypography.caption)
                .foregroundColor(.white.opacity(0.7))

            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.vyncModeEnabled ? Color(hex: 0x4ADE80) : Color.white.opacity(0.36))
                    .frame(width: 8, height: 8)
                Text(viewModel.vyncModeEnabled ? "Currently enabled" : "Currently disabled")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(viewModel.vyncModeEnabled ? Color(hex: 0x4ADE80) : .white.opacity(0.7))
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x0F172A), Color(hex: 0x4C1D95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Security Features")

            NavigationLink {
                EncryptionKeysView()
            } label: {
                featureRow(
                    icon: "lock.fill",
                    tint: SanchrColors.primary,
                    background: Color(hex: 0xEEF2FF),
                    title: "End-to-End Encryption",
                    subtitle: "All messages secured",
                    showsStatusDot: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                EncryptionKeysView()
            } label: {
                featureRow(
                    icon: "qrcode",
                    tint: SanchrColors.accent,
                    background: Color(hex: 0xECFEFF),
                    title: "Security Code Verification",
                    subtitle: "Verify contacts and device keys"
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                VaultView()
            } label: {
                featureRow(
                    icon: "lock.doc.fill",
                    tint: Color(hex: 0x7C3AED),
                    background: Color(hex: 0xF3E8FF),
                    title: "Vault Messages",
                    subtitle: "Self-destructing media and secure storage"
                )
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                stackedToggleRow(
                    icon: "faceid",
                    tint: Color(hex: 0x16A34A),
                    background: Color(hex: 0xDCFCE7),
                    title: "Biometric Lock",
                    subtitle: viewModel.biometricLock ? "App lock enabled" : "Require Face ID or Touch ID",
                    isOn: $viewModel.biometricLock
                ) { newValue in
                    container.appLockManager.biometricLockEnabled = newValue
                    if newValue {
                        authenticateBiometric()
                    } else {
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
                }

                Divider()
                    .padding(.leading, 56)

                HStack(spacing: 14) {
                    iconTile(systemName: "lock.rectangle.fill", tint: Color(hex: 0x2563EB), background: Color(hex: 0xDBEAFE))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Screen Lock Timeout")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text(timeoutLabel(viewModel.screenLockTimeout))
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }

                    Spacer()

                    Menu {
                        ForEach(screenLockTimeouts, id: \.1) { label, value in
                            Button(label) {
                                viewModel.screenLockEnabled = true
                                viewModel.screenLockTimeout = value
                                container.appLockManager.screenLockEnabled = true
                                container.appLockManager.screenLockTimeout = value
                                viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textTertiary)
                    }
                }
                .padding(.vertical, 12)
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

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Privacy Settings")

            VStack(spacing: 0) {
                stackedToggleRow(
                    icon: "checkmark.message.fill",
                    tint: SanchrColors.primary,
                    background: Color(hex: 0xEEF2FF),
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
                    tint: Color(hex: 0x16A34A),
                    background: Color(hex: 0xDCFCE7),
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
                    tint: Color(hex: 0xDC2626),
                    background: Color(hex: 0xFEE2E2),
                    title: "Screenshot Protection",
                    subtitle: "Prevent screenshots and screen recording",
                    isOn: $viewModel.screenshotProtection
                ) { newValue in
                    container.appLockManager.screenshotProtectionEnabled = newValue
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }
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

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Account")

            Button {
                showChangePassword = true
            } label: {
                featureRow(
                    icon: "key.fill",
                    tint: Color(hex: 0xCA8A04),
                    background: Color(hex: 0xFEF3C7),
                    title: "Change Password",
                    subtitle: "Update your account credentials"
                )
            }
            .buttonStyle(.plain)

            featureRow(
                icon: "desktopcomputer",
                tint: Color(hex: 0x6B7280),
                background: Color(hex: 0xF3F4F6),
                title: "Active Sessions",
                subtitle: "1 device connected"
            )

            Button {
                showDeleteAccount = true
            } label: {
                featureRow(
                    icon: "trash.fill",
                    tint: Color(hex: 0xDC2626),
                    background: Color(hex: 0xFEE2E2),
                    title: "Delete Account",
                    subtitle: "Permanently erase your account and data"
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

    private func featureRow(
        icon: String,
        tint: Color,
        background: Color,
        title: String,
        subtitle: String,
        showsStatusDot: Bool = false
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

            HStack(spacing: 8) {
                if showsStatusDot {
                    Circle()
                        .fill(Color(hex: 0x22C55E))
                        .frame(width: 8, height: 8)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
            }
        }
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
        }
    }

    private func stackedToggleRow(
        icon: String,
        tint: Color,
        background: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onChange: @escaping (Bool) -> Void
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
                .onChange(of: isOn.wrappedValue) { _, newValue in
                    onChange(newValue)
                }
        }
        .padding(.vertical, 12)
    }

    private func iconTile(systemName: String, tint: Color, background: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(SanchrExportColors.surfaceMuted)
            .frame(width: 42, height: 42)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.sanchrPrimary)
            }
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
            }
        }
    }
}

struct ChangePasswordSheet: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    field(title: "Current password", text: $currentPassword)
                    field(title: "New password", text: $newPassword)
                    field(title: "Confirm new password", text: $confirmPassword)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(SanchrTypography.caption)
                            .foregroundColor(.sanchrError)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await changePassword() }
                    } label: {
                        if isProcessing {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(
                                    LinearGradient(
                                        colors: [SanchrColors.primary, SanchrColors.primaryDark],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(Capsule())
                        } else {
                            SanchrGradientButtonLabel(title: "Change Password", systemName: nil)
                        }
                    }
                    .buttonStyle(SanchrPrimaryCTA())
                    .disabled(isProcessing || newPassword.isEmpty || newPassword != confirmPassword)
                    .opacity(isProcessing || newPassword.isEmpty || newPassword != confirmPassword ? 0.6 : 1)
                }
                .padding(SanchrExportMetrics.sectionHorizontal)
                .padding(.top, 16)
            }
            .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func field(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)

            SecureField(title, text: text)
                .font(SanchrTypography.body)
                .padding(.horizontal, 18)
                .frame(height: 56)
                .background(SanchrExportColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                }
        }
    }

    private func changePassword() async {
        guard newPassword == confirmPassword else {
            errorMessage = "Passwords do not match."
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        do {
            try await container.authService.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

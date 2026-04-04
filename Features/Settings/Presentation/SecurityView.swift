import LocalAuthentication
import SwiftUI

/// Security settings screen.
/// Matches Figma: security-screen.
/// Syncs screen lock, biometric, screenshot protection, and VyncMode to backend.
struct SecurityView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = SettingsViewModel()
    @State private var showChangePassword = false

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
        List {
            // MARK: - Screen Lock
            Section("Screen Lock") {
                Toggle("Screen lock", isOn: $viewModel.screenLockEnabled)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.screenLockEnabled) { _, newValue in
                        container.appLockManager.screenLockEnabled = newValue
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }

                if viewModel.screenLockEnabled {
                    // Timeout picker
                    Picker("Lock timeout", selection: $viewModel.screenLockTimeout) {
                        ForEach(screenLockTimeouts, id: \.1) { name, value in
                            Text(name).tag(value)
                        }
                    }
                    .onChange(of: viewModel.screenLockTimeout) { _, newValue in
                        container.appLockManager.screenLockTimeout = newValue
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Biometric Lock
            Section {
                Toggle("Face ID / Touch ID", isOn: $viewModel.biometricLock)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.biometricLock) { _, newValue in
                        container.appLockManager.biometricLockEnabled = newValue
                        if newValue {
                            authenticateBiometric()
                        } else {
                            viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                        }
                    }

                Text("Require biometric authentication to open Sanchr.")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Screenshot Protection
            Section {
                Toggle("Screenshot protection", isOn: $viewModel.screenshotProtection)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.screenshotProtection) { _, newValue in
                        container.appLockManager.screenshotProtectionEnabled = newValue
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }

                Text("Prevents screenshots and screen recording within the app.")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Vync Mode
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                        HStack(spacing: SanchrSpacing.xxs) {
                            Text("Vync Mode")
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                            // Badge
                            Text("Enhanced")
                                .font(SanchrTypography.micro)
                                .foregroundColor(.sanchrPrimary)
                                .padding(.horizontal, SanchrSpacing.xxs)
                                .padding(.vertical, SanchrSpacing.xxxs)
                                .background(Color.sanchrPrimary.opacity(0.1))
                                .clipShape(Capsule())
                        }

                        Text(
                            "Maximum privacy: no read receipts, no typing, no online status, no screenshots"
                        )
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    }

                    Spacer()

                    Toggle("", isOn: $viewModel.vyncModeEnabled)
                        .tint(.sanchrPrimary)
                        .labelsHidden()
                        .onChange(of: viewModel.vyncModeEnabled) { _, _ in
                            Task {
                                await viewModel.toggleVyncMode(
                                    settingsDataSource: settingsDataSource)
                            }
                        }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Change Password
            Section("Account") {
                Button {
                    showChangePassword = true
                } label: {
                    HStack {
                        Image(systemName: "key.fill")
                            .foregroundColor(.sanchrPrimary)
                            .frame(width: 28)
                        Text("Change password")
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Advanced
            Section("Advanced") {
                Button {
                    // Show active sessions
                } label: {
                    HStack {
                        Text("Active sessions")
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        Spacer()
                        Text("1 device")
                            .font(SanchrTypography.caption)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    }
                }

                NavigationLink {
                    EncryptionKeysView()
                } label: {
                    Text("Encryption keys")
                        .font(SanchrTypography.body)
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showChangePassword) {
            ChangePasswordSheet()
        }
        .task {
            await viewModel.loadSettings(
                settingsDataSource: settingsDataSource,
                appLockManager: container.appLockManager
            )
        }
    }

    // MARK: - Biometric Auth

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

// MARK: - Change Password Sheet

struct ChangePasswordSheet: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SecureField("Current password", text: $currentPassword)
                    SecureField("New password", text: $newPassword)
                    SecureField("Confirm new password", text: $confirmPassword)
                }
                .listRowBackground(Color.sanchrSurface(colorScheme))

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(SanchrTypography.caption)
                            .foregroundColor(.sanchrError)
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    Button {
                        Task { await changePassword() }
                    } label: {
                        HStack {
                            Spacer()
                            if isProcessing {
                                ProgressView()
                            } else {
                                Text("Change Password")
                                    .font(SanchrTypography.button)
                                    .foregroundColor(.sanchrPrimary)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isProcessing || newPassword.isEmpty || newPassword != confirmPassword)
                }
                .listRowBackground(Color.sanchrSurface(colorScheme))
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
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

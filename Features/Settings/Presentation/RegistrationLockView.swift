import SwiftUI
import SanchrShared

// MARK: - RegistrationLockView

/// Settings screen to enable, disable, or change the Registration Lock PIN.
///
/// Registration Lock prevents someone who has obtained your phone number from
/// re-registering on a new device without your PIN.
///
/// State machine:
///   .idle        → shows current enabled/disabled status + action button
///   .enterNew    → PINEntryView for the new PIN (first entry)
///   .confirmNew  → PINEntryView to confirm the new PIN (second entry)
///   .enterCurrent → PINEntryView required to disable an existing lock
struct RegistrationLockView: View {

    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = SettingsViewModel()
    @State private var phase: Phase = .idle
    @State private var pendingPIN: String? = nil
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var showSuccess = false

    private enum Phase {
        case idle
        case enterNew
        case confirmNew
        case enterCurrent
    }

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    var body: some View {
        ZStack {
            switch phase {
            case .idle:
                idleScreen
            case .enterNew:
                PINEntryView(
                    title: "Create PIN",
                    subtitle: "Choose a 6-digit PIN you'll remember. You'll need it to re-register.",
                    isConfirmation: false,
                    onComplete: { pin in
                        pendingPIN = pin
                        phase = .confirmNew
                    },
                    onCancel: {
                        phase = .idle
                    }
                )
            case .confirmNew:
                PINEntryView(
                    title: "Confirm PIN",
                    subtitle: "Enter your new PIN again to confirm.",
                    isConfirmation: true,
                    onComplete: { confirmedPIN in
                        if confirmedPIN == pendingPIN {
                            Task { await enableLock(pin: confirmedPIN) }
                        } else {
                            // Mismatch — go back to first entry
                            pendingPIN = nil
                            phase = .enterNew
                            errorMessage = "PINs didn't match. Try again."
                        }
                    },
                    onCancel: {
                        pendingPIN = nil
                        phase = .enterNew
                    }
                )
            case .enterCurrent:
                PINEntryView(
                    title: "Enter PIN",
                    subtitle: "Enter your current Registration Lock PIN to disable it.",
                    isConfirmation: false,
                    onComplete: { pin in
                        Task { await disableLock(pin: pin) }
                    },
                    onCancel: {
                        phase = .idle
                    }
                )
            }

            // Loading overlay
            if isLoading {
                Color.black.opacity(0.3).ignoresSafeArea()
                ProgressView()
                    .tint(SanchrColors.primary)
                    .scaleEffect(1.4)
            }
        }
        .task {
            await viewModel.loadSettings(
                settingsDataSource: settingsDataSource,
                privacySettings: container.privacySettings
            )
        }
    }

    // MARK: - Idle Screen

    private var idleScreen: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                statusCard
                explainerCard
                actionSection
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.bottom, 28)
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .sanchrSettingsSubscreenNavigation(title: "Registration Lock")
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let msg = errorMessage { Text(msg) }
        }
        .overlay(successToast, alignment: .bottom)
    }

    // MARK: - Status Card

    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(viewModel.registrationLockEnabled
                          ? SanchrColors.primary.opacity(0.15)
                          : SanchrExportColors.surfaceCard)
                    .frame(width: 52, height: 52)
                Image(systemName: viewModel.registrationLockEnabled ? "lock.fill" : "lock.open")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(viewModel.registrationLockEnabled
                                     ? SanchrColors.primary
                                     : SanchrExportColors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.registrationLockEnabled ? "Enabled" : "Disabled")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(viewModel.registrationLockEnabled
                                     ? SanchrColors.primary
                                     : SanchrExportColors.textPrimary)

                Text(viewModel.registrationLockEnabled
                     ? "Your account is protected with a PIN"
                     : "Anyone with your number could re-register")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Circle()
                .fill(viewModel.registrationLockEnabled ? SanchrColors.success : SanchrExportColors.line)
                .frame(width: 10, height: 10)
        }
        .padding(20)
        .settingsCard(cornerRadius: 24)
    }

    // MARK: - Explainer Card

    private var explainerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("How it works", systemImage: "info.circle")
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)

            VStack(alignment: .leading, spacing: 10) {
                bulletPoint(
                    icon: "iphone.and.arrow.forward",
                    text: "If someone tries to register with your number on a new device, they'll need your PIN."
                )
                bulletPoint(
                    icon: "key.fill",
                    text: "Choose a PIN you'll remember — losing it means a 7-day waiting period to regain access."
                )
                bulletPoint(
                    icon: "arrow.clockwise",
                    text: "You can change or disable the lock at any time."
                )
            }
        }
        .padding(20)
        .settingsCard(cornerRadius: 24)
    }

    private func bulletPoint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SanchrColors.primary)
                .frame(width: 18)
                .padding(.top, 2)
            Text(text)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(SanchrExportColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        VStack(spacing: 12) {
            if viewModel.registrationLockEnabled {
                Button {
                    phase = .enterNew
                } label: {
                    actionLabel("Change PIN", icon: "pencil", role: .primary)
                }
                .buttonStyle(.plain)

                Button {
                    phase = .enterCurrent
                } label: {
                    actionLabel("Disable Registration Lock", icon: "lock.open", role: .destructive)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    phase = .enterNew
                } label: {
                    actionLabel("Enable Registration Lock", icon: "lock.fill", role: .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private enum ActionRole { case primary, destructive }

    private func actionLabel(_ title: String, icon: String, role: ActionRole) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(role == .destructive ? SanchrColors.error : SanchrColors.primary)
                .frame(width: 32)
            Text(title)
                .font(SanchrTypography.bodyBold)
                .foregroundColor(role == .destructive ? SanchrColors.error : SanchrExportColors.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SanchrExportColors.textTertiary)
        }
        .padding(16)
        .settingsCard()
    }

    // MARK: - Success Toast

    private var successToast: some View {
        Group {
            if showSuccess {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                    Text(viewModel.registrationLockEnabled ? "Registration Lock enabled" : "Registration Lock disabled")
                        .font(SanchrTypography.captionSmall)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(SanchrColors.primary, in: Capsule())
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func enableLock(pin: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resp = try await settingsDataSource.setRegistrationLock(enabled: true, pin: pin)
            if resp.success {
                viewModel.registrationLockEnabled = true
                pendingPIN = nil
                phase = .idle
                withAnimation { showSuccess = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation { showSuccess = false }
                }
            } else {
                errorMessage = "The server couldn't enable the lock. Please try again."
                phase = .idle
            }
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    @MainActor
    private func disableLock(pin: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resp = try await settingsDataSource.setRegistrationLock(enabled: false, pin: pin)
            if resp.success {
                viewModel.registrationLockEnabled = false
                phase = .idle
                withAnimation { showSuccess = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation { showSuccess = false }
                }
            } else {
                errorMessage = "Incorrect PIN. Please try again."
                phase = .idle
            }
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }
}

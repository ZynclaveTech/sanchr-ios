import SwiftUI
import SanchrShared

/// Two-step confirmation sheet for permanent account deletion.
///
/// Local @State owns the flow (`isDeletingAccount`, `deleteAccountError`)
/// and delegates to `container.authService.deleteAccount()`. On success
/// the shared `SessionService` flips `isAuthenticated` to false, which the
/// existing root navigation observer already uses to route back to
/// onboarding.
struct DeleteAccountConfirmationSheet: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var acknowledged = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    warningHeader
                    consequencesList
                    acknowledgementToggle

                    if let deleteAccountError {
                        errorBanner(message: deleteAccountError)
                    }

                    deleteButton
                }
                .padding(SanchrExportMetrics.sectionHorizontal)
                .padding(.top, 16)
            }
                .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeletingAccount)
                }
            }
            .interactiveDismissDisabled(isDeletingAccount)
        }
    }

    // MARK: - Subviews

    private var warningHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsIconTile(systemName: "exclamationmark.triangle", role: .destructive, size: 48, iconSize: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text("This cannot be undone")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text("Deleting your account permanently removes your profile, messages, keys, and backups from Sanchr's servers.")
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var consequencesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            consequence("Your messages will be deleted from this device and any linked devices.")
            consequence("Your phone number will be released and may be reused by a new account.")
            consequence("Encrypted backups tied to this account will be destroyed and cannot be restored.")
            consequence("Contacts will no longer see you on Sanchr.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SanchrExportColors.line.opacity(0.55), lineWidth: 1)
        }
    }

    private func consequence(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.circle")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.sanchrError)
                .padding(.top, 2)
            Text(text)
                .font(SanchrTypography.caption)
                .foregroundColor(SanchrExportColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var acknowledgementToggle: some View {
        Toggle(isOn: $acknowledged) {
            Text("I understand this cannot be undone")
                .font(SanchrTypography.bodyBold)
                .foregroundColor(SanchrExportColors.textPrimary)
        }
        .toggleStyle(SwitchToggleStyle(tint: Color.sanchrError))
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SanchrExportColors.line.opacity(0.55), lineWidth: 1)
        }
        .disabled(isDeletingAccount)
    }

    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.sanchrError)
            Text(message)
                .font(SanchrTypography.caption)
                .foregroundColor(.sanchrError)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.sanchrError.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var deleteButton: some View {
        Button {
            Task { await performDelete() }
        } label: {
            HStack {
                if isDeletingAccount {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "trash")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 16, weight: .semibold))
                    Text("Delete My Account")
                        .font(SanchrTypography.bodyBold)
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.sanchrError)
            .clipShape(Capsule())
        }
        .disabled(!acknowledged || isDeletingAccount)
        .opacity((!acknowledged || isDeletingAccount) ? 0.6 : 1)
        .accessibilityIdentifier("deleteAccountConfirmButton")
    }

    // MARK: - Actions

    private func performDelete() async {
        guard acknowledged, !isDeletingAccount else { return }

        isDeletingAccount = true
        deleteAccountError = nil
        defer { isDeletingAccount = false }

        do {
            try await container.authService.deleteAccount()
            // SessionService has already flipped `isAuthenticated` to false
            // and wiped local + App Group state. The root navigation observer
            // will route back to onboarding; we just close the sheet.
            dismiss()
        } catch {
            deleteAccountError = error.localizedDescription
        }
    }
}

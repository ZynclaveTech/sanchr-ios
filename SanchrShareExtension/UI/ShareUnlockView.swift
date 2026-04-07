import SwiftUI
import LocalAuthentication
import SanchrShared

/// Biometric / passcode gate shown before the share extension exposes any
/// chat data, when the host app has screen lock enabled.
///
/// We deliberately use `.deviceOwnerAuthentication` (not the
/// `…WithBiometrics` variant) so the system automatically falls back to the
/// device passcode when Face ID / Touch ID is unavailable, not enrolled, or
/// has too many failed attempts. This matches the main app's
/// `AppLockManager.unlockWithPasscodeIfAvailable()` behaviour.
///
/// Note: the main app's `AppLockManager` lives in the host module, not in
/// `SanchrShared`, so we can't reuse the type directly here. The contract
/// (same `LAPolicy`, same localized reason) is preserved by sharing the
/// reason string and policy choice instead.
struct ShareUnlockView: View {

    let onUnlocked: () -> Void
    let onCancel: () -> Void

    @State private var errorMessage: String?
    @State private var isAuthenticating: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 56))
                .foregroundColor(SanchrColors.primary)

            Text("Sanchr is locked")
                .font(.title3.weight(.semibold))

            Text("Unlock to share into Sanchr.")
                .font(.body)
                .foregroundColor(SanchrExportColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: authenticate) {
                    Text("Unlock")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(SanchrColors.primary)
                        .cornerRadius(14)
                }
                .disabled(isAuthenticating)

                Button("Cancel", role: .cancel, action: onCancel)
                    .foregroundColor(SanchrColors.primary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .task {
            // Auto-prompt as soon as the view appears so users don't have to
            // tap an extra button in the common case.
            authenticate()
        }
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            isAuthenticating = false
            errorMessage = policyError?.localizedDescription
                ?? "Authentication is not available on this device."
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock Sanchr to share"
        ) { success, evalError in
            DispatchQueue.main.async {
                isAuthenticating = false
                if success {
                    onUnlocked()
                } else if let laError = evalError as? LAError, laError.code == .userCancel {
                    // User explicitly tapped Cancel inside the LA prompt — leave
                    // the view in place so they can retry without an error.
                    errorMessage = nil
                } else {
                    errorMessage = evalError?.localizedDescription
                        ?? "Authentication failed."
                }
            }
        }
    }
}

#Preview {
    ShareUnlockView(onUnlocked: {}, onCancel: {})
}

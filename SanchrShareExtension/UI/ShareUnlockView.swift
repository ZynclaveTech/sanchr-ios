import LocalAuthentication
import SanchrShared
import SwiftUI

/// Biometric / passcode gate shown before the share extension exposes any
/// chat data, when the host app has screen lock enabled.
///
/// The screen itself is the app's `LockScreenView`, so the two never drift.
/// The prompt stays here: the main app's `AppLockManager` lives in the host
/// module, and this extension can also be dismissed instead of unlocked.
///
/// We deliberately use `.deviceOwnerAuthentication` (not the
/// `…WithBiometrics` variant) so the system falls back to the device
/// passcode when Face ID / Touch ID is unavailable, not enrolled, or has
/// too many failed attempts.
struct ShareUnlockView: View {

    let onUnlocked: () -> Void
    let onCancel: () -> Void

    @State private var errorMessage: String?
    @State private var isAuthenticating: Bool = false

    var body: some View {
        LockScreenView(
            isAuthenticating: isAuthenticating,
            errorMessage: errorMessage,
            subtitle: "Unlock to share into Sanchr.",
            onUnlock: authenticate,
            onCancel: onCancel
        )
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
            errorMessage = policyError.map { LockScreenView.message(for: $0) }
                ?? "Set a device passcode to unlock Sanchr."
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
                } else if let evalError {
                    // A cancel inside the prompt leaves the screen in place
                    // with nothing to explain.
                    errorMessage = LockScreenView.message(for: evalError)
                } else {
                    errorMessage = "Couldn't unlock. Try again."
                }
            }
        }
    }
}

#Preview {
    ShareUnlockView(onUnlocked: {}, onCancel: {})
}

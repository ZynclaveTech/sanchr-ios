import LocalAuthentication
import SanchrShared
import SwiftUI

/// Gate view that blocks app access until the device owner authenticates.
/// Shown at cold launch if App Lock is enabled.
///
/// Uses `.deviceOwnerAuthentication`, the same policy as the share
/// extension's unlock: Face ID / Touch ID when enrolled, with the device
/// passcode as the fallback. The biometrics-only policy this used to
/// request left anyone without biometrics enrolled — or with a failed Face
/// ID — locked out of their own app with no way in.
struct AppLockGateView: View {
    @Binding var isAuthenticated: Bool
    @State private var authError: String?
    @State private var isAuthenticating = false

    var body: some View {
        LockScreenView(isAuthenticating: isAuthenticating, errorMessage: authError, onUnlock: authenticate)
            .onAppear {
                // Prompt straight away; the button is for a second try.
                authenticate()
            }
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authError = error?.localizedDescription ?? "Set a device passcode to unlock Sanchr."
            return
        }

        isAuthenticating = true
        authError = nil

        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Unlock Sanchr"
                )

                if success {
                    isAuthenticated = true
                } else {
                    authError = "Couldn't unlock. Try again."
                }
            } catch {
                authError = LockScreenView.message(for: error)
            }

            isAuthenticating = false
        }
    }
}

#Preview {
    AppLockGateView(isAuthenticated: .constant(false))
}

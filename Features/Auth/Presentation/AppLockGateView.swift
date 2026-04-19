import LocalAuthentication
import SwiftUI

/// Gate view that blocks app access until biometric authentication succeeds.
/// Shown at cold launch if biometric lock is enabled.
struct AppLockGateView: View {
    @Binding var isAuthenticated: Bool
    @State private var authError: String?
    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            // Solid background — no preview of content behind
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.white)

                Text("App Locked")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)

                if let error = authError {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                Button(action: authenticate) {
                    if isAuthenticating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Unlock")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .disabled(isAuthenticating)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white)
                .foregroundColor(.black)
                .cornerRadius(8)
            }
            .padding(20)
        }
        .onAppear {
            // Attempt biometric auth immediately on appearance
            authenticate()
        }
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            authError = error?.localizedDescription ?? "Biometric not available"
            return
        }

        isAuthenticating = true
        authError = nil

        Task {
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Unlock Sanchr"
                )

                if success {
                    isAuthenticated = true
                } else {
                    authError = "Authentication failed"
                }
            } catch {
                authError = error.localizedDescription
            }

            isAuthenticating = false
        }
    }
}

#Preview {
    AppLockGateView(isAuthenticated: .constant(false))
}

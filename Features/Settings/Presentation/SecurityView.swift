import SwiftUI

/// Security settings screen.
/// Matches Figma: security-screen.
struct SecurityView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var biometricLock = false
    @State private var autoLockInterval = "1 minute"
    @State private var registrationLock = true

    private let autoLockOptions = ["Immediately", "1 minute", "5 minutes", "15 minutes", "1 hour"]

    var body: some View {
        List {
            Section("App Lock") {
                Toggle("Face ID / Touch ID", isOn: $biometricLock)
                    .tint(.sanchrPrimary)

                if biometricLock {
                    Picker("Auto-lock", selection: $autoLockInterval) {
                        ForEach(autoLockOptions, id: \.self) { Text($0) }
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Account") {
                Toggle("Registration lock", isOn: $registrationLock)
                    .tint(.sanchrPrimary)

                Text("Require your PIN when registering your phone number with Sanchr again.")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Advanced") {
                Button {
                    // TODO: Show active sessions
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
    }
}

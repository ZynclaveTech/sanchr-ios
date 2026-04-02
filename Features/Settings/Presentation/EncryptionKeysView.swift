import SwiftUI

/// Encryption key management screen.
/// Matches Figma: encryption-keys-screen.
struct EncryptionKeysView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var identityKeyFingerprint: String = "Loading..."
    @State private var preKeyCount: Int = 0

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: SanchrSpacing.sm) {
                    HStack(spacing: SanchrSpacing.xs) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.sanchrSuccess)
                        Text("End-to-end encryption active")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    }

                    Text("Messages, calls, and files are secured with the Signal Protocol. Only you and the recipient can read your messages.")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Your Identity Key") {
                VStack(alignment: .leading, spacing: SanchrSpacing.xs) {
                    Text(identityKeyFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    Button {
                        // TODO: Copy fingerprint to clipboard
                        UIPasteboard.general.string = identityKeyFingerprint
                    } label: {
                        Label("Copy fingerprint", systemImage: "doc.on.doc")
                            .font(SanchrTypography.caption)
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Key Information") {
                HStack {
                    Text("Pre-keys remaining")
                    Spacer()
                    Text("\(preKeyCount)")
                        .foregroundColor(
                            preKeyCount < 10 ? .sanchrError : Color.sanchrTextSecondary(colorScheme)
                        )
                }

                Button {
                    // TODO: Regenerate pre-keys
                } label: {
                    Text("Regenerate pre-keys")
                        .font(SanchrTypography.body)
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section {
                Button(role: .destructive) {
                    // TODO: Reset all encryption keys (dangerous)
                } label: {
                    Text("Reset encryption keys")
                }

                Text("This will end all active encrypted sessions. You will need to verify your identity with all contacts again.")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Encryption Keys")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadKeyInfo()
        }
    }

    private func loadKeyInfo() async {
        // TODO: Load actual key info from KeyManager
        if let pubKey = try? await container.keyManager.localIdentityPublicKey() {
            let hex = pubKey.map { String(format: "%02x", $0) }.joined(separator: " ")
            identityKeyFingerprint = hex
        } else {
            identityKeyFingerprint = "No identity key generated"
        }
    }
}

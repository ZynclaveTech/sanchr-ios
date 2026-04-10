import SwiftUI
import SanchrShared

/// Encryption key management screen.
/// Matches Figma: encryption-keys-screen.
/// Displays identity key fingerprint, safety number verification, signed pre-key info,
/// and one-time pre-key count from the local Signal Protocol store.
struct EncryptionKeysView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var identityKeyFingerprint: String = "Loading..."
    @State private var preKeyCount: Int? = nil
    @State private var signedPreKeyAge: String = ""
    @State private var copiedToClipboard = false
    @State private var isLoadingMetadata = false
    @State private var showingShareSheet = false
    @State private var showingResetAlert = false
    @State private var isResettingKeys = false
    @State private var resetError: String? = nil

    var body: some View {
        List {
            // MARK: - Encryption Status
            Section {
                VStack(alignment: .leading, spacing: SanchrSpacing.sm) {
                    HStack(spacing: SanchrSpacing.xs) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.sanchrSuccess)
                        Text("End-to-end encryption active")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    }

                    Text(
                        "Messages, calls, and files are secured with the Signal Protocol. Only you and the recipient can read your messages."
                    )
                    .font(SanchrTypography.caption)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Identity Key Fingerprint
            Section("Your Identity Key") {
                VStack(alignment: .leading, spacing: SanchrSpacing.xs) {
                    Text(identityKeyFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        .textSelection(.enabled)

                    HStack(spacing: SanchrSpacing.sm) {
                        Button {
                            UIPasteboard.general.string = identityKeyFingerprint
                            copiedToClipboard = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedToClipboard = false
                            }
                        } label: {
                            Label(
                                copiedToClipboard ? "Copied!" : "Copy fingerprint",
                                systemImage: copiedToClipboard ? "checkmark" : "doc.on.doc"
                            )
                            .font(SanchrTypography.caption)
                            .foregroundColor(copiedToClipboard ? .sanchrSuccess : .sanchrPrimary)
                        }

                        Button {
                            showingShareSheet = true
                        } label: {
                            Label("Share", systemImage: "qrcode")
                                .font(SanchrTypography.caption)
                        }
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(items: [identityKeyFingerprint])
            }

            // MARK: - Safety Number Verification
            Section("Safety Number Verification") {
                VStack(alignment: .leading, spacing: SanchrSpacing.xs) {
                    Text("Compare this number with your contact to verify end-to-end encryption.")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))

                    Button {
                        // no-op — safety number verification is per-conversation
                    } label: {
                        HStack(spacing: SanchrSpacing.xs) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title3)
                            Text("Scan Safety Number")
                                .font(SanchrTypography.body)
                        }
                        .foregroundColor(.sanchrPrimary)
                    }
                    .disabled(true)
                    .opacity(0.5)

                    Text("Open a conversation to verify safety numbers with a specific contact.")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Signed Pre-Key
            Section("Signed Pre-Key") {
                HStack {
                    Text("Status")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    Spacer()
                    HStack(spacing: SanchrSpacing.xxs) {
                        Circle()
                            .fill(Color.sanchrSuccess)
                            .frame(width: 8, height: 8)
                        Text("Active")
                            .font(SanchrTypography.caption)
                            .foregroundColor(.sanchrSuccess)
                    }
                }

                HStack {
                    Text("Age")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    Spacer()
                    Text(signedPreKeyAge)
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }

                Text("Signed pre-keys are rotated periodically to maintain forward secrecy.")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - One-Time Pre-Keys
            Section("One-Time Pre-Keys") {
                HStack {
                    Text("Remaining")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    Spacer()
                    Text(preKeyCount.map { "\($0)" } ?? "—")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(
                            preKeyCount.map { $0 < 10 } == true
                                ? .sanchrError
                                : preKeyCount.map { $0 < 50 } == true
                                    ? .sanchrWarning : Color.sanchrTextSecondary(colorScheme)
                        )
                }

                if preKeyCount.map({ $0 < 10 }) == true {
                    HStack(spacing: SanchrSpacing.xxs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.sanchrWarning)
                        Text("Pre-key supply is low. Regenerate to maintain secure messaging.")
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(.sanchrWarning)
                    }
                }

                Button {
                    Task { await regeneratePreKeys() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Regenerate pre-keys")
                    }
                    .font(SanchrTypography.body)
                    .foregroundColor(.sanchrPrimary)
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Reset Keys (Dangerous)
            Section {
                Button(role: .destructive) {
                    showingResetAlert = true
                } label: {
                    Text(isResettingKeys ? "Resetting…" : "Reset encryption keys")
                }
                .disabled(isResettingKeys)
                .alert("Reset Encryption Keys?", isPresented: $showingResetAlert) {
                    Button("Reset", role: .destructive) {
                        Task {
                            isResettingKeys = true
                            do {
                                try await container.keyManager.resetIdentityKeys()
                            } catch {
                                resetError = error.localizedDescription
                            }
                            isResettingKeys = false
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "This will generate new encryption keys and invalidate all existing sessions. All contacts will see a safety number change. This cannot be undone."
                    )
                }
                .alert("Reset Failed", isPresented: Binding(
                    get: { resetError != nil },
                    set: { if !$0 { resetError = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(resetError ?? "")
                }

                Text(
                    "This will end all active encrypted sessions. You will need to verify your identity with all contacts again."
                )
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

    // MARK: - Key Info Loading

    private func loadKeyInfo() async {
        isLoadingMetadata = true
        defer { isLoadingMetadata = false }

        if container.keyManager.hasIdentityKeys,
            let identity = try? container.keyManager.generateIdentityIfNeeded()
        {
            let pubKeyBytes = identity.identityKey.publicKey.serialize()
            let hex = pubKeyBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            identityKeyFingerprint = hex
        } else {
            identityKeyFingerprint = "No identity key generated"
        }

        if let count = try? await container.keyManager.fetchPreKeyCount() {
            preKeyCount = count
        }

        if let date = try? container.keyManager.signedPreKeyCreatedAt() {
            let days = Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
            signedPreKeyAge = days == 0 ? "Today" : "\(days) day\(days == 1 ? "" : "s") ago"
        } else {
            signedPreKeyAge = "Unknown"
        }
    }

    // MARK: - ShareSheet

    private struct ShareSheet: UIViewControllerRepresentable {
        let items: [Any]
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }
        func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
    }

    private func regeneratePreKeys() async {
        do {
            try await container.keyManager.replenishPreKeys()
            if let count = try? await container.keyManager.fetchPreKeyCount() {
                preKeyCount = count
            }
            SanchrLogger.crypto.info("One-time pre-keys replenished")
        } catch {
            SanchrLogger.crypto.error("Failed to replenish pre-keys: \(error)")
        }
    }
}

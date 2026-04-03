import SwiftUI

/// Contact sync screen requesting permission and showing sync progress.
/// Matches Figma: contact-sync-screen.
struct ContactSyncView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var isSyncing = false
    @State private var syncComplete = false
    @State private var foundContacts: [User] = []
    @State private var errorMessage: String?
    @State private var syncProgress: Double = 0.0

    var body: some View {
        VStack(spacing: SanchrSpacing.xxl) {
            Spacer()

            if syncComplete {
                syncResultsView
            } else if isSyncing {
                syncProgressView
            } else {
                permissionRequestView
            }

            Spacer()

            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(SanchrTypography.caption)
                    .foregroundColor(.sanchrError)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SanchrSpacing.xl)
            }

            // Action buttons
            if !syncComplete {
                VStack(spacing: SanchrSpacing.md) {
                    // Sync Contacts gradient button
                    Button {
                        Task { await syncContacts() }
                    } label: {
                        Group {
                            if isSyncing {
                                HStack(spacing: SanchrSpacing.xs) {
                                    ProgressView()
                                        .tint(.white)
                                    Text("Syncing...")
                                }
                            } else {
                                Text("Sync Contacts")
                            }
                        }
                        .font(SanchrTypography.button)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SanchrSpacing.sm)
                        .background(SanchrGradients.primary)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                        .sanchrPrimaryGlow()
                    }
                    .disabled(isSyncing)

                    // Skip link
                    Button {
                        dismiss()
                    } label: {
                        Text("Skip")
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    }
                    .disabled(isSyncing)
                }
                .padding(.horizontal, SanchrSpacing.xl)
                .padding(.bottom, SanchrSpacing.xl)
            } else {
                Button {
                    dismiss()
                } label: {
                    Text("Continue")
                        .font(SanchrTypography.button)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SanchrSpacing.sm)
                        .background(SanchrGradients.primary)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
                        .sanchrPrimaryGlow()
                }
                .padding(.horizontal, SanchrSpacing.xl)
                .padding(.bottom, SanchrSpacing.xl)
            }
        }
        .sanchrScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Permission Request View

    private var permissionRequestView: some View {
        VStack(spacing: SanchrSpacing.lg) {
            // Illustration: contacts icon with shield
            ZStack {
                Circle()
                    .fill(Color.sanchrPrimary.opacity(0.1))
                    .frame(width: 120, height: 120)

                Image(systemName: "person.2.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(SanchrGradients.primary)

                Image(systemName: "shield.checkered")
                    .font(.system(size: 24))
                    .foregroundColor(.sanchrSuccess)
                    .offset(x: 36, y: 36)
            }

            // Title
            Text("Find Your Friends")
                .font(SanchrTypography.screenTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))

            // Description
            Text(
                "Sanchr uses secure contact discovery to find your friends. Your contacts are hashed locally and never stored on our servers."
            )
            .font(SanchrTypography.body)
            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            .multilineTextAlignment(.center)
            .padding(.horizontal, SanchrSpacing.lg)

            // Permission cards
            VStack(spacing: SanchrSpacing.sm) {
                permissionCard(
                    icon: "lock.fill",
                    title: "Private & Secure",
                    subtitle: "Your contacts never leave your device in plain text"
                )

                permissionCard(
                    icon: "number",
                    title: "Hash Only",
                    subtitle: "Phone numbers are SHA-256 hashed before transmission"
                )

                permissionCard(
                    icon: "cpu",
                    title: "Local Processing",
                    subtitle: "All hashing happens on your device, not our servers"
                )
            }
            .padding(.horizontal, SanchrSpacing.xl)
        }
        .padding(.horizontal, SanchrSpacing.md)
    }

    // MARK: - Permission Card

    private func permissionCard(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: SanchrSpacing.sm) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.sanchrPrimary)
                .frame(width: 32, height: 32)
                .background(Color.sanchrPrimary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.sm))

            VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            }

            Spacer()
        }
        .padding(SanchrSpacing.sm)
        .background(Color.sanchrSurfaceElevated(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
    }

    // MARK: - Sync Progress View

    private var syncProgressView: some View {
        VStack(spacing: SanchrSpacing.lg) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.sanchrPrimary)

            Text("Syncing Contacts...")
                .font(SanchrTypography.cardTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))

            Text("Finding your friends on Sanchr")
                .font(SanchrTypography.body)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))

            // Privacy badge
            HStack(spacing: SanchrSpacing.xxs) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                Text("Privacy-first contact discovery")
                    .font(SanchrTypography.captionSmall)
            }
            .foregroundColor(SanchrColors.encryptionBadgeText)
            .padding(.horizontal, SanchrSpacing.sm)
            .padding(.vertical, SanchrSpacing.xxs)
            .background(SanchrColors.encryptionBadge)
            .clipShape(Capsule())
        }
    }

    // MARK: - Sync Results View

    private var syncResultsView: some View {
        VStack(spacing: SanchrSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.sanchrSuccess)

            Text("Contacts Synced!")
                .font(SanchrTypography.screenTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))

            Text("\(foundContacts.count) friends found on Sanchr")
                .font(SanchrTypography.bodyLarge)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))

            // Show matched contacts preview
            if !foundContacts.isEmpty {
                VStack(spacing: SanchrSpacing.xs) {
                    ForEach(foundContacts.prefix(5)) { contact in
                        HStack(spacing: SanchrSpacing.sm) {
                            Circle()
                                .fill(Color.sanchrPrimary.opacity(0.2))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    Text(contact.displayName.prefix(1).uppercased())
                                        .font(SanchrTypography.caption)
                                        .foregroundColor(.sanchrPrimary)
                                }

                            Text(contact.displayName)
                                .font(SanchrTypography.body)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                            Spacer()

                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.sanchrSuccess)
                        }
                    }

                    if foundContacts.count > 5 {
                        Text("and \(foundContacts.count - 5) more...")
                            .font(SanchrTypography.caption)
                            .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                    }
                }
                .padding(SanchrSpacing.md)
                .background(Color.sanchrSurfaceElevated(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.card))
                .padding(.horizontal, SanchrSpacing.xl)
            }
        }
    }

    // MARK: - Sync Action

    private func syncContacts() async {
        isSyncing = true
        errorMessage = nil

        let contactDataSource = ContactDataSource(
            grpcClient: container.grpcClient,
            localDatabase: container.localDatabase
        )
        let useCase = ContactUseCases.SyncContacts(contactDataSource: contactDataSource)

        do {
            foundContacts = try await useCase.execute()
            syncComplete = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isSyncing = false
    }
}

import SwiftUI

/// Contact sync screen requesting permission and showing sync progress.
/// Matches Figma: contact-sync-screen.
struct ContactSyncView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var isSyncing = false
    @State private var syncComplete = false
    @State private var foundContacts: [User] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: SanchrSpacing.xxl) {
            Spacer()

            if syncComplete {
                // MARK: - Sync Results
                VStack(spacing: SanchrSpacing.md) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.sanchrSuccess)

                    Text("Contacts synced")
                        .font(SanchrTypography.screenTitle)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    Text("Found \(foundContacts.count) contacts on Sanchr")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
            } else {
                // MARK: - Permission Request
                VStack(spacing: SanchrSpacing.md) {
                    Image(systemName: "person.2.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(SanchrGradients.primary)

                    Text("Find your friends")
                        .font(SanchrTypography.screenTitle)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    Text("Sanchr will check your contacts to find people you know. Your contacts are hashed and never stored on our servers.")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        .multilineTextAlignment(.center)

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
                .padding(.horizontal, SanchrSpacing.xl)
            }

            Spacer()

            if let error = errorMessage {
                Text(error)
                    .font(SanchrTypography.caption)
                    .foregroundColor(.sanchrError)
            }

            if !syncComplete {
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
                }
                .disabled(isSyncing)
                .padding(.horizontal, SanchrSpacing.xl)
                .padding(.bottom, SanchrSpacing.xl)
            }
        }
        .sanchrScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func syncContacts() async {
        isSyncing = true
        errorMessage = nil

        let useCase = SyncContactsUseCase(contactRepository: container.contactRepository)
        do {
            foundContacts = try await useCase.execute()
            syncComplete = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isSyncing = false
    }
}

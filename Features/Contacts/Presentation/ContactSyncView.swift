import SwiftUI
import SanchrShared

/// Contact sync screen requesting permission and showing sync progress.
/// Matches Figma: contact-sync-screen.
struct ContactSyncView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var isSyncing = false
    @State private var syncComplete = false
    @State private var foundContacts: [User] = []
    @State private var errorMessage: String?
    let onBack: (() -> Void)?
    let onFinish: (() -> Void)?

    init(onBack: (() -> Void)? = nil, onFinish: (() -> Void)? = nil) {
        self.onBack = onBack
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            SanchrCenteredHeader(
                title: "Sync Contacts",
                leading: {
                    SanchrIconButton(systemName: "arrow.left", foreground: SanchrExportColors.textSecondary) {
                        if let onBack {
                            onBack()
                        } else {
                            dismiss()
                        }
                    }
                },
                trailing: {
                    if syncComplete || isSyncing {
                        Color.clear
                    } else {
                        Button("Skip") {
                            finishFlow()
                        }
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(.sanchrPrimary)
                    }
                }
            )

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    if syncComplete {
                        syncResultsView
                    } else if isSyncing {
                        syncProgressView
                    } else {
                        permissionRequestView
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(SanchrTypography.caption)
                            .foregroundColor(.sanchrError)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }

            footerActions
        }
        .sanchrExportBackground()
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Permission Request View

    private var permissionRequestView: some View {
        VStack(spacing: 28) {
            ZStack(alignment: .bottomTrailing) {
                Image("SanchrLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                Circle()
                    .fill(SanchrColors.accent)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .offset(x: 8, y: 8)
            }
            .padding(.top, 8)

            Text("Find Your Friends")
                .font(SanchrTypography.displayTitle)
                .foregroundColor(SanchrExportColors.textPrimary)

            Text(
                "Sync your contacts to see who's already on Sanchr and start secure conversations"
            )
            .font(SanchrTypography.body)
            .foregroundColor(SanchrExportColors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)

            VStack(spacing: SanchrSpacing.sm) {
                permissionCard(
                    icon: "shield.fill",
                    title: "Private & Secure",
                    subtitle: "Your contacts are encrypted and never shared with third parties",
                    tint: SanchrColors.primary
                )

                permissionCard(
                    icon: "person.badge.shield.checkmark.fill",
                    title: "Instant Matching",
                    subtitle: "Automatically find friends who are already using Sanchr",
                    tint: SanchrColors.accent
                )

                permissionCard(
                    icon: "hand.raised.fill",
                    title: "No Spam, Ever",
                    subtitle: "We won't send notifications to your contacts without your permission",
                    tint: Color(hex: 0x64748B)
                )
            }
        }
    }

    // MARK: - Permission Card

    private func permissionCard(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: SanchrSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.sanchrPrimary)
                .frame(width: 44, height: 44)
                .background(SanchrExportColors.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()
        }
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: SanchrExportMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SanchrExportMetrics.cardRadius, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }

    // MARK: - Sync Progress View

    private var syncProgressView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.sanchrPrimary)

            Text("Syncing Contacts...")
                .font(SanchrTypography.sectionHeader)
                .foregroundColor(SanchrExportColors.textPrimary)

            Text("Securely encrypting and matching your contacts...")
                .font(SanchrTypography.body)
                .foregroundColor(SanchrExportColors.textSecondary)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                Text("Privacy-first contact discovery")
                    .font(SanchrTypography.caption)
            }
            .foregroundColor(SanchrColors.encryptionBadgeText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SanchrColors.encryptionBadge)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Sync Results View

    private var syncResultsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.sanchrSuccess)

            Text("Contacts Synced!")
                .font(SanchrTypography.screenTitle)
                .foregroundColor(SanchrExportColors.textPrimary)

            Text("Found \(foundContacts.count) friends on Sanchr")
                .font(SanchrTypography.bodyLarge)
                .foregroundColor(SanchrExportColors.textSecondary)

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
                                .foregroundColor(SanchrExportColors.textPrimary)

                            Spacer()

                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.sanchrSuccess)
                        }
                    }

                    if foundContacts.count > 5 {
                        Text("and \(foundContacts.count - 5) more...")
                            .font(SanchrTypography.caption)
                            .foregroundColor(SanchrExportColors.textTertiary)
                    }
                }
                .padding(18)
                .background(SanchrExportColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: SanchrExportMetrics.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SanchrExportMetrics.cardRadius, style: .continuous)
                        .stroke(SanchrExportColors.line, lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Footer Actions

    private var footerActions: some View {
        VStack(spacing: 12) {
            if syncComplete {
                Button(action: finishFlow) {
                    SanchrGradientButtonLabel(title: "Continue to Sanchr", systemName: nil)
                }
                .buttonStyle(SanchrPrimaryCTA())
            } else {
                Button {
                    Task { await syncContacts() }
                } label: {
                    SanchrGradientButtonLabel(
                        title: isSyncing ? "Syncing..." : "Sync All Contacts",
                        systemName: nil
                    )
                }
                .buttonStyle(SanchrPrimaryCTA())
                .disabled(isSyncing)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .background(SanchrExportColors.background)
    }

    // MARK: - Sync Action

    private func syncContacts() async {
        isSyncing = true
        errorMessage = nil

        let contactDataSource = ContactDataSource(
            grpcClient: container.grpcClient,
            localDatabase: container.localDatabase
        )
        let useCase = ContactUseCases.SyncContacts(
            contactDataSource: contactDataSource,
            discoveryRepository: container.discoveryRepository
        )

        do {
            foundContacts = try await useCase.execute()
            syncComplete = true
        } catch AppError.featureDisabled {
            errorMessage =
                "Contact discovery isn't available on the server yet. You can still start chats by entering a phone number."
        } catch {
            // localizedDescription on a GRPCStatus always renders "error 1",
            // naming neither the status code nor the message. Log the real one.
            SanchrLogger.sync.error(
                "Contact sync failed: \(SignalSessionManager.detailedError(error))")
            errorMessage = error.localizedDescription
        }

        isSyncing = false
    }

    private func finishFlow() {
        if let onFinish {
            onFinish()
        } else {
            dismiss()
        }
    }
}

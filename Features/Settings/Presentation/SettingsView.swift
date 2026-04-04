import Kingfisher
import SwiftUI

/// Main settings screen.
/// Matches Figma: settings-screen.
struct SettingsView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = SettingsViewModel()

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    var body: some View {
        List {
            // MARK: - Profile Section
            Section {
                NavigationLink {
                    ProfileView()
                } label: {
                    HStack(spacing: SanchrSpacing.sm) {
                        // Avatar
                        if let url = URL(string: viewModel.avatarURL), !viewModel.avatarURL.isEmpty
                        {
                            KFImage(url)
                                .resizable()
                                .placeholder { profileAvatarPlaceholder }
                                .fade(duration: 0.2)
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                        } else {
                            profileAvatarPlaceholder
                        }

                        VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                            Text(viewModel.displayName)
                                .font(SanchrTypography.bodyBold)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                            Text(viewModel.phoneNumber)
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                            if !viewModel.statusText.isEmpty {
                                Text(viewModel.statusText)
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - General Section
            Section {
                settingsRow(
                    icon: "paintbrush.fill", title: "Appearance", destination: AppearanceView())
                settingsRow(
                    icon: "bell.fill", title: "Notifications", destination: NotificationsView())
                settingsRow(
                    icon: "bubble.left.fill", title: "Chat Settings",
                    destination: ChatSettingsView())
                settingsRow(
                    icon: "externaldrive.fill", title: "Storage & Data", destination: StorageView())
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Privacy & Security
            Section {
                settingsRow(icon: "hand.raised.fill", title: "Privacy", destination: PrivacyView())
                settingsRow(
                    icon: "lock.shield.fill", title: "Security", destination: SecurityView())
                settingsRow(
                    icon: "key.fill", title: "Encryption Keys", destination: EncryptionKeysView())
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Support
            Section {
                settingsRow(
                    icon: "questionmark.circle.fill", title: "Help Center",
                    destination: HelpCenterView())
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Vault
            Section {
                NavigationLink {
                    VaultView()
                } label: {
                    HStack(spacing: SanchrSpacing.sm) {
                        Image(systemName: "lock.doc.fill")
                            .foregroundColor(.sanchrPrimary)
                            .frame(width: 28)
                        Text("Vault")
                            .font(SanchrTypography.body)
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Version
            Section {
                HStack {
                    Spacer()
                    Text("Sanchr v\(viewModel.appVersion)")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                    Spacer()
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .task {
            viewModel.loadProfile(from: container.sessionService)
            await viewModel.loadSettings(
                settingsDataSource: settingsDataSource,
                appLockManager: container.appLockManager
            )
        }
    }

    // MARK: - Helpers

    private var profileAvatarPlaceholder: some View {
        Circle()
            .fill(Color.sanchrPrimary.opacity(0.2))
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.title2)
                    .foregroundColor(.sanchrPrimary)
            }
    }

    private func settingsRow<Destination: View>(
        icon: String,
        title: String,
        destination: Destination
    ) -> some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: SanchrSpacing.sm) {
                Image(systemName: icon)
                    .foregroundColor(.sanchrPrimary)
                    .frame(width: 28)
                Text(title)
                    .font(SanchrTypography.body)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))
            }
        }
    }
}

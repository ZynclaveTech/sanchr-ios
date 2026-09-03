import SwiftUI
import SanchrShared

/// Privacy settings screen.
/// Matches Figma: privacy-screen.
/// All toggles sync to the backend via SettingsService.UpdateSettings.
struct PrivacyView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = SettingsViewModel()

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    private let visibilityOptions = ["everyone", "contacts", "nobody"]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                sanchrModeCard
                accountPrivacySection
                securityFeaturesSection
                controlsSection
                blockedContactsSection

                SettingsErrorLabel(message: viewModel.errorMessage)
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.bottom, 28)
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .sanchrSettingsSubscreenNavigation(title: "Privacy")
        .task {
            await viewModel.loadSettings(
                settingsDataSource: settingsDataSource,
                privacySettings: container.privacySettings
            )
        }
    }

    private var sanchrModeCard: some View {
        SanchrModeCard(
            isOn: $viewModel.sanchrModeEnabled,
            onToggleChanged: { newValue in
                await viewModel.setSanchrMode(enabled: newValue, settingsDataSource: settingsDataSource)
            }
        )
    }

    private var accountPrivacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Account Privacy")

            Menu {
                visibilityMenuSelection(for: $viewModel.profilePhotoVisibility, syncsToBackend: true)
            } label: {
                cardRow(
                    icon: "person.crop.circle",
                    title: "Profile Photo",
                    subtitle: displayVisibility(viewModel.profilePhotoVisibility),
                    trailing: AnyView(chevron)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 14) {
                iconTile(systemName: "checkmark.message")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Read Receipts")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text(viewModel.readReceipts ? "Enabled" : "Disabled")
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $viewModel.readReceipts)
                    .labelsHidden()
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.readReceipts) { _, _ in
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
            }
            .padding(16)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var securityFeaturesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Security Features")

            NavigationLink {
                SecurityView()
            } label: {
                cardRow(
                    icon: "lock",
                    title: "App Lock",
                    subtitle: "Biometric and timeout controls",
                    trailing: AnyView(chevron)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink {
                VaultView()
            } label: {
                cardRow(
                    icon: "lock.doc",
                    title: "Secret Vault",
                    subtitle: "Hide sensitive files and chats",
                    trailing: AnyView(chevron)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Privacy Controls")

            VStack(spacing: 0) {
                stackedToggleRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Online Status",
                    subtitle: "Let trusted contacts know when you're active",
                    isOn: $viewModel.onlineStatusVisible
                ) {
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                Divider()
                    .padding(.leading, 56)

                stackedToggleRow(
                    icon: "keyboard",
                    title: "Typing Indicators",
                    subtitle: "Show when you're composing a message",
                    isOn: $viewModel.typingIndicator
                ) {
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var blockedContactsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Blocked Contacts")

            NavigationLink {
                BlockedContactsView()
            } label: {
                cardRow(
                    icon: "hand.raised",
                    title: "Blocked contacts",
                    subtitle: "Review and unblock people at any time",
                    trailing: AnyView(chevron)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        SettingsSectionTitle(title: title)
    }

    private func cardRow(
        icon: String,
        title: String,
        subtitle: String,
        trailing: AnyView
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            trailing
        }
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func stackedToggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onChange: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.sanchrPrimary)
                .onChange(of: isOn.wrappedValue) { _, _ in
                    onChange()
                }
        }
        .padding(.vertical, 12)
    }

    private func iconTile(systemName: String) -> some View {
        SettingsIconTile(systemName: systemName)
    }

    private var chevron: some View {
        SettingsChevron()
    }

    @ViewBuilder
    private func visibilityMenuSelection(for binding: Binding<String>, syncsToBackend: Bool) -> some View {
        ForEach(visibilityOptions, id: \.self) { option in
            Button(displayVisibility(option)) {
                binding.wrappedValue = option
                if syncsToBackend {
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }
            }
        }
    }

    private func displayVisibility(_ value: String) -> String {
        switch value {
        case "everyone":
            return "Everyone"
        case "contacts":
            return "My Contacts"
        case "nobody":
            return "Nobody"
        default:
            return value.capitalized
        }
    }
}

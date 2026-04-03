import SwiftUI

/// Privacy settings screen.
/// Matches Figma: privacy-screen.
/// All toggles sync to the backend via SettingsService.UpdateSettings.
struct PrivacyView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = SettingsViewModel()

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    private let visibilityOptions = ["everyone", "contacts", "nobody"]

    private let disappearingOptions = [
        ("Off", "off"),
        ("24 hours", "24h"),
        ("7 days", "7d"),
        ("90 days", "90d"),
    ]

    var body: some View {
        List {
            // MARK: - Read Receipts
            Section {
                Toggle("Read receipts", isOn: $viewModel.readReceipts)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.readReceipts) { _, _ in
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }

                Text("When disabled, you won't see read receipts from others either.")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Online Status
            Section {
                Toggle("Online status", isOn: $viewModel.onlineStatusVisible)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.onlineStatusVisible) { _, _ in
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }

                Text("When disabled, you won't see other users' online status.")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Typing Indicator
            Section {
                Toggle("Typing indicators", isOn: $viewModel.typingIndicator)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.typingIndicator) { _, _ in
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Profile Photo Visibility
            Section("Profile Photo Visibility") {
                ForEach(visibilityOptions, id: \.self) { option in
                    HStack {
                        Text(option.capitalized)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                        Spacer()

                        if viewModel.profilePhotoVisibility == option {
                            Image(systemName: "checkmark")
                                .foregroundColor(.sanchrPrimary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.profilePhotoVisibility = option
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Disappearing Messages Default
            Section("Disappearing Messages Default") {
                ForEach(disappearingOptions, id: \.1) { name, _ in
                    HStack {
                        Text(name)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }

                Text("Set a default timer for disappearing messages in new chats.")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Blocked Contacts
            Section {
                NavigationLink {
                    BlockedContactsView()
                } label: {
                    HStack {
                        Text("Blocked contacts")
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        Spacer()
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadSettings(settingsDataSource: settingsDataSource)
        }
    }
}

// MARK: - Blocked Contacts View

/// Sub-screen showing the list of blocked contacts with unblock actions.
struct BlockedContactsView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var blockedIDs: [String] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .tint(.sanchrPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if blockedIDs.isEmpty {
                VStack(spacing: SanchrSpacing.md) {
                    Image(systemName: "hand.raised.slash")
                        .font(.system(size: 48))
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                    Text("No blocked contacts")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(blockedIDs, id: \.self) { userId in
                        HStack {
                            Text(userId.prefix(12) + "...")
                                .font(SanchrTypography.body)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                            Spacer()
                            Button("Unblock") {
                                Task { await unblock(userId: userId) }
                            }
                            .font(SanchrTypography.caption)
                            .foregroundColor(.sanchrError)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Blocked Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadBlocked()
        }
    }

    private func loadBlocked() async {
        isLoading = true
        defer { isLoading = false }

        let dataSource = ContactDataSource(
            grpcClient: container.grpcClient,
            localDatabase: container.localDatabase
        )
        do {
            blockedIDs = try await dataSource.getBlockedList()
        } catch {
            SanchrLogger.sync.error("Failed to load blocked list: \(error.localizedDescription)")
        }
    }

    private func unblock(userId: String) async {
        let dataSource = ContactDataSource(
            grpcClient: container.grpcClient,
            localDatabase: container.localDatabase
        )
        do {
            try await dataSource.unblockContact(userId: userId)
            blockedIDs.removeAll { $0 == userId }
        } catch {
            SanchrLogger.sync.error("Failed to unblock: \(error.localizedDescription)")
        }
    }
}

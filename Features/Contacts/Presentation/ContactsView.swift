import SwiftUI

/// Contact list screen showing Sanchr contacts with alphabetical grouping.
/// Matches Figma: contact-screen.
struct ContactsView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = ContactsViewModel()

    var body: some View {
        Group {
            if viewModel.contacts.isEmpty && !viewModel.isLoading {
                emptyState
            } else {
                contactList
            }
        }
        .navigationTitle("Contacts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // Add contact by phone number
                } label: {
                    Image(systemName: "person.badge.plus")
                        .foregroundColor(.sanchrPrimary)
                }
            }
        }
        .refreshable {
            await viewModel.refreshContacts(
                contactDataSource: contactDataSource,
                localDatabase: container.localDatabase
            )
        }
        .task {
            await viewModel.loadContacts(
                contactDataSource: contactDataSource,
                localDatabase: container.localDatabase
            )
            await viewModel.loadBlockedList(contactDataSource: contactDataSource)
        }
    }

    // MARK: - Contact Data Source (computed)

    private var contactDataSource: ContactDataSource {
        ContactDataSource(grpcClient: container.grpcClient, localDatabase: container.localDatabase)
    }

    // MARK: - Contact List

    private var contactList: some View {
        List {
            // Sync prompt
            if !viewModel.hasCompletedSync {
                NavigationLink {
                    ContactSyncView()
                } label: {
                    HStack(spacing: SanchrSpacing.sm) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.title2)
                            .foregroundColor(.sanchrPrimary)
                        VStack(alignment: .leading) {
                            Text("Find your contacts")
                                .font(SanchrTypography.bodyBold)
                            Text("See who is on Sanchr")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        }
                    }
                }
                .listRowBackground(Color.sanchrSurface(colorScheme))
            }

            // Online count header
            if viewModel.onlineCount > 0 {
                Section {
                    HStack(spacing: SanchrSpacing.xxs) {
                        Circle()
                            .fill(Color.sanchrSuccess)
                            .frame(width: 8, height: 8)
                        Text("\(viewModel.onlineCount) online")
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    }
                }
                .listRowBackground(Color.clear)
            }

            // Alphabetical sections
            ForEach(viewModel.groupedContacts, id: \.letter) { group in
                Section {
                    ForEach(group.contacts) { contact in
                        ContactRow(contact: contact, colorScheme: colorScheme)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task {
                                        await viewModel.blockContact(
                                            userId: contact.id,
                                            contactDataSource: contactDataSource
                                        )
                                    }
                                } label: {
                                    Label("Block", systemImage: "hand.raised.fill")
                                }

                                Button {
                                    // Navigate to chat
                                } label: {
                                    Label("Message", systemImage: "bubble.left.fill")
                                }
                                .tint(.sanchrPrimary)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    // Initiate call
                                } label: {
                                    Label("Call", systemImage: "phone.fill")
                                }
                                .tint(.sanchrSuccess)
                            }
                            .contextMenu {
                                Button {
                                    // View profile
                                } label: {
                                    Label("View Profile", systemImage: "person.circle")
                                }

                                Button {
                                    // Navigate to chat
                                } label: {
                                    Label("Message", systemImage: "bubble.left.fill")
                                }

                                Button {
                                    // Voice call
                                } label: {
                                    Label("Voice Call", systemImage: "phone.fill")
                                }

                                Button {
                                    // Video call
                                } label: {
                                    Label("Video Call", systemImage: "video.fill")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    Task {
                                        await viewModel.blockContact(
                                            userId: contact.id,
                                            contactDataSource: contactDataSource
                                        )
                                    }
                                } label: {
                                    Label("Block", systemImage: "hand.raised.fill")
                                }
                            }
                            .listRowBackground(Color.sanchrSurface(colorScheme))
                    }
                } header: {
                    Text(group.letter)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $viewModel.searchText, prompt: "Search contacts")
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: SanchrSpacing.md) {
            Image(systemName: "person.2.circle")
                .font(.system(size: 64))
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))

            Text("No contacts yet")
                .font(SanchrTypography.cardTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))

            Text("Sync your contacts to find friends on Sanchr")
                .font(SanchrTypography.caption)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                .multilineTextAlignment(.center)

            NavigationLink {
                ContactSyncView()
            } label: {
                Text("Sync your contacts")
                    .font(SanchrTypography.button)
                    .foregroundColor(.white)
                    .padding(.horizontal, SanchrSpacing.xl)
                    .padding(.vertical, SanchrSpacing.sm)
                    .background(SanchrGradients.primary)
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.button))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sanchrScreenBackground()
    }
}

// MARK: - Contact Row

struct ContactRow: View {
    let contact: User
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: SanchrSpacing.sm) {
            // Avatar (48pt circle)
            ZStack {
                if let avatarURL = contact.avatarURL {
                    AsyncImage(url: avatarURL) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        avatarPlaceholder
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                } else {
                    avatarPlaceholder
                }

                // Online indicator (green dot)
                if contact.status == .online {
                    Circle()
                        .fill(Color.sanchrSuccess)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color.sanchrSurface(colorScheme), lineWidth: 2)
                        )
                        .frame(
                            maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: 48, height: 48)

            // Name and status
            VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                HStack(spacing: SanchrSpacing.xxs) {
                    Text(contact.displayName)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    if contact.isVerified {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundColor(.sanchrSuccess)
                    }
                }

                if let bio = contact.bio, !bio.isEmpty {
                    Text(bio)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        .lineLimit(1)
                } else {
                    Text(contact.status == .online ? "Online" : "Offline")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(
                            contact.status == .online
                                ? Color.sanchrSuccess
                                : Color.sanchrTextTertiary(colorScheme)
                        )
                }
            }

            Spacer()

            // Online indicator for non-avatar display
            if contact.status == .online {
                Circle()
                    .fill(Color.sanchrSuccess)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, SanchrSpacing.xxxs)
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color.sanchrPrimary.opacity(0.2))
            .frame(width: 48, height: 48)
            .overlay {
                Text(contact.displayName.prefix(1).uppercased())
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(.sanchrPrimary)
            }
    }
}

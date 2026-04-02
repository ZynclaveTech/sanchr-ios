import SwiftUI

/// Contact list screen showing Sanchr contacts.
/// Matches Figma: contact-screen.
struct ContactsView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = ContactsViewModel()
    @State private var searchText = ""

    var body: some View {
        Group {
            if viewModel.contacts.isEmpty && !viewModel.isLoading {
                emptyState
            } else {
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

                    // Contact list
                    ForEach(viewModel.filteredContacts(searchText: searchText)) { contact in
                        ContactRow(contact: contact, colorScheme: colorScheme)
                            .listRowBackground(Color.sanchrSurface(colorScheme))
                    }
                }
                .listStyle(.plain)
                .searchable(text: $searchText, prompt: "Search contacts")
            }
        }
        .navigationTitle("Contacts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // TODO: Add contact by phone number
                } label: {
                    Image(systemName: "person.badge.plus")
                        .foregroundColor(.sanchrPrimary)
                }
            }
        }
        .refreshable {
            await viewModel.refreshContacts(contactRepository: container.contactRepository)
        }
        .task {
            await viewModel.loadContacts(contactRepository: container.contactRepository)
        }
    }

    private var emptyState: some View {
        VStack(spacing: SanchrSpacing.md) {
            Image(systemName: "person.2.circle")
                .font(.system(size: 64))
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            Text("No contacts yet")
                .font(SanchrTypography.cardTitle)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
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
            Circle()
                .fill(Color.sanchrPrimary.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(contact.displayName.prefix(1).uppercased())
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(.sanchrPrimary)
                }

            VStack(alignment: .leading, spacing: SanchrSpacing.xxxs) {
                HStack {
                    Text(contact.displayName)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    if contact.isVerified {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundColor(.sanchrSuccess)
                    }
                }

                if let bio = contact.bio {
                    Text(bio)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        .lineLimit(1)
                }
            }

            Spacer()

            // Online indicator
            if contact.status == .online {
                Circle()
                    .fill(Color.sanchrSuccess)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, SanchrSpacing.xxxs)
    }
}

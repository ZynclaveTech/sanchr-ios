import Kingfisher
import SwiftUI
import SanchrShared

struct ContactsView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = ContactsViewModel()
    @State private var navigateToConversation: Conversation?
    @State private var isStartingChat = false

    var body: some View {
        Group {
            if viewModel.contacts.isEmpty && viewModel.isLoading {
                loadingState
            } else if viewModel.contacts.isEmpty {
                emptyState
            } else {
                contactList
            }
        }
        .navigationBarHidden(true)
        .sanchrInteractivePopEnabled()
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
        .navigationDestination(item: $navigateToConversation) { conversation in
            ChatDetailView(conversation: conversation)
        }
    }

    private var contactDataSource: ContactDataSource {
        ContactDataSource(grpcClient: container.grpcClient, localDatabase: container.localDatabase)
    }

    private func startChat(with contact: User) {
        guard !isStartingChat else { return }
        isStartingChat = true

        Task {
            defer { isStartingChat = false }

            do {
                let protoConversation = try await container.chatDataSource.startDirectConversation(
                    recipientID: contact.id
                )

                let localUserId = container.sessionService.currentUserId
                var contactsLookup: [String: User] = [contact.id: contact]
                if let localUserId {
                    contactsLookup[localUserId] = User(
                        id: localUserId,
                        phoneNumber: container.sessionService.currentPhoneNumber ?? "",
                        displayName: container.sessionService.currentDisplayName ?? "You",
                        avatarURL: nil,
                        bio: nil,
                        isVerified: true,
                        lastSeen: nil,
                        identityKeyFingerprint: nil,
                        status: .online,
                        isLocalUser: true
                    )
                }

                let conversation = ChatDataSource.mapToDomainConversation(
                    protoConversation,
                    contactsLookup: contactsLookup,
                    localUserId: localUserId
                )
                try await container.localDatabase.saveConversation(conversation)
                NotificationCenter.default.postConversationStateDidChange(
                    conversationId: conversation.id
                )
                navigateToConversation = conversation
            } catch {
                viewModel.errorMessage = "Failed to start chat: \(error.localizedDescription)"
                SanchrLogger.chat.error("startDirectConversation failed: \(error)")
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 0) {
            customHeader
            Spacer()
            ProgressView()
                .tint(.sanchrPrimary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SanchrExportColors.background)
    }

    private var customHeader: some View {
        HStack {
            Text("Contacts")
                .font(SanchrTypography.sectionHeader)
                .foregroundColor(SanchrExportColors.textPrimary)

            Spacer()

            SanchrIconButton(systemName: "person.badge.plus") {}
        }
        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
        .padding(.top, SanchrExportMetrics.rootTop)
        .padding(.bottom, 8)
        .background(SanchrExportColors.background)
    }

    private var searchBar: some View {
        SanchrSearchField(placeholder: "Search contacts...", text: $viewModel.searchText) {
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(SanchrExportColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var contactList: some View {
        List {
            Section {
                customHeader
                    .listRowInsets(EdgeInsets())

                searchBar
                    .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
                    .listRowInsets(EdgeInsets())

                if viewModel.onlineCount > 0 {
                    onlineChip
                        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                        .padding(.top, 2)
                        .listRowInsets(EdgeInsets())
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(SanchrExportColors.background)

            ForEach(viewModel.groupedContacts) { group in
                Section {
                    ForEach(group.contacts) { contact in
                        Button {
                            startChat(with: contact)
                        } label: {
                            ContactRow(contact: contact)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                startChat(with: contact)
                            } label: {
                                Label("Message", systemImage: "bubble.left.fill")
                            }
                            .tint(.sanchrPrimary)

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
                        .listRowInsets(EdgeInsets())
                    }
                } header: {
                    SanchrSectionEyebrow(title: group.letter)
                        .textCase(nil)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(SanchrExportColors.background)
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrError)
                        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                        .listRowInsets(EdgeInsets())
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                Color.clear
                    .frame(height: 70)
                    .listRowInsets(EdgeInsets())
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(SanchrExportColors.background)
        .scrollDismissesKeyboard(.interactively)
    }

    private var onlineChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(SanchrColors.statusOnline)
                .frame(width: 10, height: 10)

            Text("\(viewModel.onlineCount) online now")
                .font(SanchrTypography.conversationPreviewBold)
                .foregroundColor(SanchrExportColors.textSecondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(SanchrExportColors.surfaceMuted)
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            customHeader

            Spacer()

            VStack(spacing: 18) {
                Circle()
                    .fill(SanchrColors.primary.opacity(0.12))
                    .frame(width: 104, height: 104)
                    .overlay {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(SanchrGradients.primaryDark)
                    }

                Text("No contacts yet")
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(SanchrExportColors.textPrimary)

                Text("Your secure Sanchr contacts will appear here after onboarding sync and discovery.")
                    .font(SanchrTypography.body)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SanchrExportColors.background)
    }
}

struct ContactRow: View {
    let contact: User

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(contact.displayName)
                        .font(SanchrTypography.conversationName)
                        .foregroundColor(SanchrExportColors.textPrimary)

                    if contact.isVerified {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(SanchrColors.accent)
                    }
                }

                Text(subtitle)
                    .font(SanchrTypography.conversationPreview)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "bubble.left.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SanchrColors.primary)
                .frame(width: 38, height: 38)
                .background(Color.sanchrPrimary.opacity(0.1))
                .clipShape(Circle())
        }
        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
        .padding(.vertical, 12)
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let avatarURL = contact.avatarURL {
                    KFImage(avatarURL)
                        .resizable()
                        .placeholder { avatarPlaceholder }
                        .fade(duration: 0.2)
                        .scaledToFill()
                } else {
                    avatarPlaceholder
                }
            }
            .frame(width: SanchrSpacing.chatAvatarSize, height: SanchrSpacing.chatAvatarSize)
            .clipShape(Circle())

            if contact.status == .online {
                Circle()
                    .fill(SanchrColors.statusOnline)
                    .frame(width: SanchrSpacing.statusIndicatorSize, height: SanchrSpacing.statusIndicatorSize)
                    .overlay {
                        Circle()
                            .stroke(Color.white, lineWidth: 2.5)
                    }
                    .offset(x: 1, y: 1)
            }
        }
        .frame(width: SanchrSpacing.chatAvatarSize, height: SanchrSpacing.chatAvatarSize)
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(SanchrColors.primary.opacity(0.14))
            .overlay {
                Text(contact.displayName.prefix(1).uppercased())
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(.sanchrPrimary)
            }
    }

    private var subtitle: String {
        if let bio = contact.bio, !bio.isEmpty {
            return bio
        }
        if !contact.phoneNumber.isEmpty {
            return contact.phoneNumber
        }
        return "Sanchr contact"
    }
}

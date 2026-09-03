import Kingfisher
import SwiftUI
import SanchrShared

// MARK: - New Chat Contact Picker
// Extracted from ChatsListView.swift on 2026-04-20 as part of god-file refactor.
// Visibility promoted from private to module-internal for cross-file access.

struct NewChatContactPickerSheet: View {
    let contactRepository: ContactRepositoryProtocol
    let localDatabase: LocalDatabaseProtocol
    let messageRepository: MessageRepositoryProtocol
    let onConversationReady: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(DependencyContainer.self) private var container
    @State private var contacts: [User] = []
    @State private var isLoadingContacts = true
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var startingContactId: String?

    private var filteredContacts: [User] {
        let sorted = contacts.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            "\($0.displayName) \($0.phoneNumber) \($0.bio ?? "")".lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SanchrCenteredHeader(title: "New Chat") {
                SanchrIconButton(systemName: "xmark") { dismiss() }
                    .accessibilityLabel("Close")
            } trailing: {
                Color.clear
            }

            SanchrSearchField(placeholder: "Search contacts...", text: $searchText) {
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(SanchrExportColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.top, SanchrSpacing.sm)
            .padding(.bottom, SanchrSpacing.xs)

            if let error = loadError {
                HStack(spacing: SanchrSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SanchrColors.error)
                    Text(error)
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrColors.error)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                }
                .padding(SanchrSpacing.sm)
                .background(SanchrColors.error.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: SanchrSpacing.sm, style: .continuous))
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                .padding(.bottom, SanchrSpacing.xs)
            }

            pickerContent
        }
        .background(SanchrExportColors.background.ignoresSafeArea())
        .task { await loadContacts() }
    }

    @ViewBuilder
    private var pickerContent: some View {
        if contacts.isEmpty && isLoadingContacts {
            Spacer()
            ProgressView().tint(.sanchrPrimary)
            Spacer()
        } else if filteredContacts.isEmpty {
            Spacer()
            VStack(spacing: SanchrSpacing.sm) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
                Text(contacts.isEmpty ? "No contacts yet" : "No matching contacts")
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text("Synced Sanchr contacts will appear here.")
                    .font(SanchrTypography.body)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            Spacer()
        } else {
            List {
                ForEach(filteredContacts) { contact in
                    NewChatContactRow(
                        isIdentityVerified: container.signalProtocol
                            .isIdentityVerified(userId: contact.id),
                        contact: contact,
                        isStarting: startingContactId == contact.id
                    ) {
                        startChat(with: contact)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(SanchrExportColors.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(SanchrExportColors.background)
        }
    }

    private func loadContacts() async {
        isLoadingContacts = true
        loadError = nil
        do {
            contacts = try await contactRepository.fetchContacts()
        } catch {
            do {
                contacts = try await localDatabase.fetchContacts()
            } catch {
                loadError = UserFacingError.message(for: error)
            }
        }
        isLoadingContacts = false
    }

    private func startChat(with contact: User) {
        guard startingContactId == nil else { return }
        startingContactId = contact.id
        Task {
            do {
                let conversationId = try await messageRepository.startDirectConversation(peerUserId: contact.id)
                onConversationReady(conversationId)
            } catch {
                startingContactId = nil
                loadError = UserFacingError.message(for: error)
            }
        }
    }
}

// Visibility promoted from private to module-internal for cross-file access.
struct NewChatContactRow: View {
    /// Whether this person's identity key has been verified — not whether they
    /// have an account. See `User.isVerified`.
    let isIdentityVerified: Bool
    let contact: User
    let isStarting: Bool
    let action: () -> Void

    private var subtitle: String {
        if let bio = contact.bio, !bio.isEmpty { return bio }
        if !contact.phoneNumber.isEmpty { return contact.phoneNumber }
        return contact.status == .online ? "Online" : "Sanchr contact"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: SanchrSpacing.sm) {
                // Avatar
                ZStack {
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

                // Name + subtitle
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(contact.displayName)
                            .font(SanchrTypography.conversationName)
                            .foregroundColor(SanchrExportColors.textPrimary)
                            .lineLimit(1)
                        if isIdentityVerified {
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

                Spacer(minLength: SanchrSpacing.xs)

                // Start indicator or chevron
                if isStarting {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SanchrExportColors.textTertiary)
                }
            }
            .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
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
}

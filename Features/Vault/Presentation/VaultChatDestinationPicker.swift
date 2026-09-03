import SwiftUI
import SanchrShared

/// Bottom-sheet conversation picker presented when the user picks
/// "Share in chat" in the destination chooser.
///
/// Lists conversations from `localDatabase.fetchConversations()` ordered
/// by last-activity timestamp, with a `.searchable` field at the top
/// that filters by conversation display name only. Message content is
/// NEVER searched — that's a privacy surface.
///
/// Tapping a conversation invokes `onConversationPicked(id, name)`
/// which the view model routes through `confirmConversation` — items
/// under 25 MB send directly, larger items transition to a confirmation
/// alert driven by the parent view.
struct VaultChatDestinationPicker: View {
    let item: VaultItem
    let localDatabase: LocalDatabaseProtocol
    let onConversationPicked: (_ conversationId: String, _ conversationName: String) -> Void
    let onCancel: () -> Void

    @State private var conversations: [Conversation] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""

    private var filteredConversations: [Conversation] {
        guard !searchText.isEmpty else { return conversations }
        return conversations.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Couldn't load conversations")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text(loadError)
                            .font(SanchrTypography.captionSmall)
                            .foregroundColor(SanchrExportColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredConversations.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No conversations" : "No matches",
                        systemImage: "message",
                        description: Text(
                            searchText.isEmpty
                                ? "Start a chat first, then come back to share."
                                : "Try a different name."
                        )
                    )
                } else {
                    List(filteredConversations, id: \.id) { conversation in
                        Button {
                            onConversationPicked(conversation.id, conversation.displayName)
                        } label: {
                            ConversationPickerRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(SanchrExportColors.background)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(SanchrExportColors.background)
                    .searchable(text: $searchText, prompt: "Search conversations")
                }
            }
            .navigationTitle("Send to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
            .background(SanchrExportColors.background.ignoresSafeArea())
        }
        .presentationDetents([.large])
        .task {
            await loadConversations()
        }
    }

    private func loadConversations() async {
        do {
            let all = try await localDatabase.fetchConversations()
            conversations = all.sorted { $0.lastActivityAt > $1.lastActivityAt }
            isLoading = false
        } catch {
            loadError = UserFacingError.message(for: error)
            isLoading = false
        }
    }
}

private struct ConversationPickerRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceMuted)
                .frame(width: 44, height: 44)
                .overlay {
                    Text(initials(for: conversation.displayName))
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayName)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .lineLimit(1)
                if let preview = Self.lastMessagePreview(for: conversation), !preview.isEmpty {
                    Text(preview)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SanchrExportColors.textTertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ").prefix(2)
        let initials = parts.compactMap { $0.first }.map(String.init).joined()
        return initials.uppercased().isEmpty ? "?" : initials.uppercased()
    }

    /// Best-effort last-message preview. The forward-secure vault
    /// rewrite doesn't expose a plaintext preview column on
    /// Conversation; use the computed last message's content type as
    /// a short human-readable hint instead of diving into encrypted
    /// content.
    private static func lastMessagePreview(for conversation: Conversation) -> String? {
        guard let last = conversation.lastMessage else { return nil }
        switch last.content {
        case .text(let body): return body
        case .image: return "📷 Photo"
        case .video: return "🎥 Video"
        case .audio: return "🎵 Audio"
        case .document: return "📄 File"
        case .location: return "📍 Location"
        case .contact: return "👤 Contact"
        case .system: return nil
        }
    }
}

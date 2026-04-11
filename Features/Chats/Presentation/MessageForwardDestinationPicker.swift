import SwiftUI
import SanchrShared

/// Bottom-sheet conversation picker for the "Forward" message action.
///
/// Lists all conversations sorted by last-activity timestamp with a
/// searchable filter.  Tapping a row invokes `onConversationPicked` with
/// the target conversation's id and display name.
struct MessageForwardDestinationPicker: View {
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
                                ? "Start a chat first."
                                : "Try a different name."
                        )
                    )
                } else {
                    List(filteredConversations, id: \.id) { conversation in
                        Button {
                            onConversationPicked(conversation.id, conversation.displayName)
                        } label: {
                            ForwardConversationRow(conversation: conversation)
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
            .navigationTitle("Forward to")
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
            loadError = error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - Row

private struct ForwardConversationRow: View {
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
                if let preview = lastMessagePreview, !preview.isEmpty {
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

    private var lastMessagePreview: String? {
        guard let last = conversation.lastMessage else { return nil }
        switch last.content {
        case .text(let body): return body
        case .image: return "Photo"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "File"
        case .location: return "Location"
        case .contact: return "Contact"
        case .system: return nil
        }
    }

    private func initials(for name: String) -> String {
        let parts = name.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").prefix(2)
        let result = parts.compactMap { $0.first }.map(String.init).joined().uppercased()
        return result.isEmpty ? "?" : result
    }
}

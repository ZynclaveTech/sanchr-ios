import SwiftUI
import SanchrShared

// MARK: - Archived Chats View
// Extracted from ChatsListView.swift on 2026-04-20 as part of god-file refactor.
// Visibility promoted from private to module-internal for cross-file access.

struct ArchivedChatsView: View {
    let localDatabase: LocalDatabaseProtocol
    let messageRepository: MessageRepositoryProtocol

    @Environment(AppRouter.self) private var router
    @State private var summaries: [ShareChatSummary] = []
    @State private var isLoading = true
    @State private var isUpdatingConversationIds: Set<String> = []
    @State private var loadError: String?
    /// A failed unarchive. Kept apart from `loadError`, which replaces the
    /// whole list with the load-failed screen.
    @State private var actionError: String?
    @State private var searchText = ""

    private var filteredSummaries: [ShareChatSummary] {
        guard !searchText.isEmpty else { return summaries }
        return summaries.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
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
                    Text("Couldn't load archived chats")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text(loadError)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSummaries.isEmpty {
                ContentUnavailableView(
                    summaries.isEmpty ? "No archived chats" : "No matches",
                    systemImage: "archivebox",
                    description: Text(
                        summaries.isEmpty
                            ? "Archived chats will appear here."
                            : "Try a different name."
                    )
                )
            } else {
                List {
                    ForEach(filteredSummaries, id: \.id) { summary in
                        ArchivedChatRow(
                            summary: summary,
                            isUpdating: isUpdatingConversationIds.contains(summary.id),
                            onOpen: { router.deepLinkToConversation(conversationId: summary.id) },
                            onUnarchive: { unarchive(summary.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(SanchrExportColors.background)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(SanchrExportColors.background)
                .searchable(text: $searchText, prompt: "Search archived chats")
            }
        }
        .navigationTitle("Archived Chats")
        .navigationBarTitleDisplayMode(.inline)
        .background(SanchrExportColors.background.ignoresSafeArea())
        .task { await loadSummaries() }
        .alert("Couldn't unarchive that chat", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @MainActor
    private func loadSummaries() async {
        do {
            summaries = try await localDatabase.fetchArchivedChatSummaries()
                .sorted { $0.lastActivityMs > $1.lastActivityMs }
            isLoading = false
            loadError = nil
        } catch {
            loadError = UserFacingError.message(for: error)
            isLoading = false
        }
    }

    @MainActor
    private func unarchive(_ conversationId: String) {
        guard !isUpdatingConversationIds.contains(conversationId) else { return }
        isUpdatingConversationIds.insert(conversationId)

        Task {
            do {
                try await messageRepository.setConversationArchived(
                    conversationId: conversationId,
                    isArchived: false
                )
                await MainActor.run {
                    summaries.removeAll { $0.id == conversationId }
                    isUpdatingConversationIds.remove(conversationId)
                    router.deepLinkToConversation(conversationId: conversationId)
                }
            } catch {
                await MainActor.run {
                    actionError = UserFacingError.message(for: error)
                    isUpdatingConversationIds.remove(conversationId)
                }
            }
        }
    }
}

// Visibility promoted from private to module-internal for cross-file access.
struct ArchivedChatRow: View {
    let summary: ShareChatSummary
    let isUpdating: Bool
    let onOpen: () -> Void
    let onUnarchive: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(SanchrExportColors.surfaceMuted)
                .frame(width: 44, height: 44)
                .overlay {
                    Text(initials(for: summary.title))
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .lineLimit(1)

                if let preview = summary.lastMessagePreview, !preview.isEmpty {
                    Text(preview)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("Archived")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                onUnarchive()
            } label: {
                if isUpdating {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(width: 24, height: 24)
                } else {
                    Text("Unarchive")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(SanchrColors.primary)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ").prefix(2)
        let initials = parts.compactMap { $0.first }.map(String.init).joined().uppercased()
        return initials.isEmpty ? "?" : initials
    }
}

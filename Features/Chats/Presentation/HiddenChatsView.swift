import SwiftUI
import SanchrShared

// MARK: - Hidden Chats View
// Extracted from ChatsListView.swift on 2026-04-20 as part of god-file refactor.
// Visibility promoted from private to module-internal for cross-file access.

struct HiddenChatsView: View {
    let localDatabase: LocalDatabaseProtocol
    let messageRepository: MessageRepositoryProtocol

    @Environment(AppRouter.self) private var router
    @State private var summaries: [ShareChatSummary] = []
    @State private var isLoading = true
    @State private var isRestoringConversationIds: Set<String> = []
    @State private var loadError: String?
    /// A failed restore. Kept apart from `loadError`, which replaces the
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
                    Text("Couldn't load hidden chats")
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
                    summaries.isEmpty ? "No hidden chats" : "No matches",
                    systemImage: "eye.slash",
                    description: Text(
                        summaries.isEmpty
                            ? "Chats removed from this device will appear here."
                            : "Try a different name."
                    )
                )
            } else {
                List {
                    ForEach(filteredSummaries, id: \.id) { summary in
                        HiddenChatRow(
                            summary: summary,
                            isRestoring: isRestoringConversationIds.contains(summary.id),
                            onOpen: { router.deepLinkToConversation(conversationId: summary.id) },
                            onRestore: { restore(summary.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(SanchrExportColors.background)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(SanchrExportColors.background)
                .searchable(text: $searchText, prompt: "Search hidden chats")
            }
        }
        .navigationTitle("Hidden Chats")
        .navigationBarTitleDisplayMode(.inline)
        .background(SanchrExportColors.background.ignoresSafeArea())
        .task { await loadSummaries() }
        .alert("Couldn't restore that chat", isPresented: Binding(
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
            summaries = try await localDatabase.fetchHiddenChatSummaries()
                .sorted { $0.lastActivityMs > $1.lastActivityMs }
            isLoading = false
            loadError = nil
        } catch {
            loadError = UserFacingError.message(for: error)
            isLoading = false
        }
    }

    @MainActor
    private func restore(_ conversationId: String) {
        guard !isRestoringConversationIds.contains(conversationId) else { return }
        isRestoringConversationIds.insert(conversationId)

        Task {
            do {
                try await messageRepository.restoreConversationLocally(conversationId: conversationId)
                await MainActor.run {
                    summaries.removeAll { $0.id == conversationId }
                    isRestoringConversationIds.remove(conversationId)
                    router.deepLinkToConversation(conversationId: conversationId)
                }
            } catch {
                await MainActor.run {
                    actionError = UserFacingError.message(for: error)
                    isRestoringConversationIds.remove(conversationId)
                }
            }
        }
    }
}

// Visibility promoted from private to module-internal for cross-file access.
struct HiddenChatRow: View {
    let summary: ShareChatSummary
    let isRestoring: Bool
    let onOpen: () -> Void
    let onRestore: () -> Void

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
                    Text("Removed from this device")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(SanchrExportColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                onRestore()
            } label: {
                if isRestoring {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(width: 24, height: 24)
                } else {
                    Text("Restore")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(SanchrColors.primary)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(isRestoring)
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

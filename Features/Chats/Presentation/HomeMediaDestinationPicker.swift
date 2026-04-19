import SwiftUI
import SanchrShared

// MARK: - Home Media Destination Picker
// Extracted from ChatsListView.swift on 2026-04-20 as part of god-file refactor.
// Visibility promoted from private to module-internal for cross-file access.

struct PendingHomeMediaSelection: Identifiable {
    let id = UUID()
    let intent: AttachmentIntent
}

// Visibility promoted from private to module-internal for cross-file access.
struct HomeMediaDestinationPicker: View {
    let localDatabase: LocalDatabaseProtocol
    let onConversationPicked: (String) -> Void
    let onCancel: () -> Void

    @State private var summaries: [ShareChatSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""

    private var filteredSummaries: [ShareChatSummary] {
        guard !searchText.isEmpty else { return summaries }
        return summaries.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
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
                        Text("Couldn't load chats")
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
                        searchText.isEmpty ? "No chats available" : "No matches",
                        systemImage: "message",
                        description: Text(
                            searchText.isEmpty
                                ? "Start a chat first, then capture media to send."
                                : "Try a different name."
                        )
                    )
                } else {
                    List(filteredSummaries, id: \.id) { summary in
                        Button {
                            onConversationPicked(summary.id)
                        } label: {
                            HomeMediaDestinationRow(summary: summary)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(SanchrExportColors.background)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(SanchrExportColors.background)
                    .searchable(text: $searchText, prompt: "Search chats")
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
        .task { await loadSummaries() }
    }

    private func loadSummaries() async {
        do {
            summaries = try await localDatabase.fetchShareChatSummaries()
                .sorted { $0.lastActivityMs > $1.lastActivityMs }
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }
}

// Visibility promoted from private to module-internal for cross-file access.
struct HomeMediaDestinationRow: View {
    let summary: ShareChatSummary

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

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                    .lineLimit(1)
                if let preview = summary.lastMessagePreview, !preview.isEmpty {
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
        let initials = parts.compactMap { $0.first }.map(String.init).joined().uppercased()
        return initials.isEmpty ? "?" : initials
    }
}

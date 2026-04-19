import Foundation
import SanchrShared

// MARK: - Search
// Extracted from ChatDetailViewModel.swift on 2026-04-20 as part of god-file refactor.
// Search state (stored properties) remains on the main class.

extension ChatDetailViewModel {

    // MARK: - Search

    func scheduleSearch(
        conversationId: String,
        query: String,
        localDatabase: LocalDatabaseProtocol
    ) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            currentSearchIndex = 0
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            do {
                let results = try await localDatabase.searchMessages(
                    conversationId: conversationId,
                    query: query
                )

                await MainActor.run {
                    guard let self, self.searchQuery == query else { return }
                    self.searchResults = results
                    self.currentSearchIndex = 0
                }
            } catch {
                await MainActor.run {
                    guard let self, self.searchQuery == query else { return }
                    SanchrLogger.chat.error("Search failed: \(error.localizedDescription)")
                    self.searchResults = []
                }
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchQuery = ""
        searchResults = []
        currentSearchIndex = 0
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
    }

    func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
    }
}

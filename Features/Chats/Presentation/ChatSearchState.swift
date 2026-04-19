import Foundation
import SanchrShared

// MARK: - ChatSearchState
// Concern-specific @Observable store for in-conversation message search.
// Owned by `ChatDetailViewModel`; the root view subscribes narrowly to
// `isSearching` / `searchResults` / `currentSearchResultId` so typing in
// the composer doesn't invalidate the search UI (and vice versa).

@Observable
@MainActor
final class ChatSearchState {
    var searchQuery: String = ""
    var searchResults: [Message] = []
    var currentSearchIndex: Int = 0
    var isSearching: Bool = false
    var searchTask: Task<Void, Never>?

    /// ID of the currently-focused search result. `nil` when results are
    /// empty. Derived from `searchResults[currentSearchIndex]` but kept as
    /// a computed property so SwiftUI can diff it via `.onChange`.
    var currentSearchResultId: String? {
        guard !searchResults.isEmpty else { return nil }
        return searchResults[currentSearchIndex].id
    }
}

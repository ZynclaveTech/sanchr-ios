import Foundation
import SanchrShared

/// Drives the SharedContentView's three tabs (Media / Links / Docs).
/// Loads paginated message batches from LocalDatabase and partitions
/// each batch into the three buckets in one pass so a single fetch
/// populates whatever tab the user lands on.
@Observable
@MainActor
final class SharedContentViewModel {
    enum Tab: String, CaseIterable, Identifiable {
        case media, links, docs
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .media: return "Media"
            case .links: return "Links"
            case .docs:  return "Docs"
            }
        }
    }

    struct LinkItem: Identifiable, Equatable, Hashable {
        let id: String              // messageId
        let url: URL
        let displayDomain: String
        let date: Date
    }

    var currentTab: Tab = .media
    var media: [Message] = []   // newest-first
    var links: [LinkItem] = []  // newest-first
    var docs: [Message] = []    // newest-first
    var isLoading: Bool = false
    var hasMore: Bool = true

    private static let pageSize = 100
    private var oldestLoadedTimestamp: Date?

    func loadInitial(
        conversationId: String,
        localDatabase: LocalDatabaseProtocol
    ) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        media.removeAll()
        links.removeAll()
        docs.removeAll()
        oldestLoadedTimestamp = nil
        hasMore = true
        await fetchPage(conversationId: conversationId, localDatabase: localDatabase)
    }

    func loadMore(
        conversationId: String,
        localDatabase: LocalDatabaseProtocol
    ) async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        await fetchPage(conversationId: conversationId, localDatabase: localDatabase)
    }

    private func fetchPage(
        conversationId: String,
        localDatabase: LocalDatabaseProtocol
    ) async {
        let batch: [Message]
        do {
            batch = try await localDatabase.fetchMessages(
                conversationId: conversationId,
                before: oldestLoadedTimestamp,
                limit: Self.pageSize
            )
        } catch {
            hasMore = false
            return
        }
        if batch.isEmpty {
            hasMore = false
            return
        }
        oldestLoadedTimestamp = batch.map(\.timestamp).min()
        if batch.count < Self.pageSize {
            hasMore = false
        }
        partition(batch)
    }

    /// Single-pass partitioning. Sorts the resulting buckets newest-first
    /// because the message batch from LocalDatabase isn't guaranteed
    /// chronological in either direction.
    private func partition(_ batch: [Message]) {
        var newMedia: [Message] = []
        var newDocs: [Message] = []
        var newLinks: [LinkItem] = []

        for message in batch {
            switch message.content {
            case .image, .video:
                newMedia.append(message)
            case .document:
                newDocs.append(message)
            case .text(let body):
                if let url = LinkPreviewService.firstURL(in: body) {
                    newLinks.append(LinkItem(
                        id: message.id,
                        url: url,
                        displayDomain: url.host ?? url.absoluteString,
                        date: message.timestamp
                    ))
                }
            default:
                break
            }
        }

        media.append(contentsOf: newMedia)
        docs.append(contentsOf: newDocs)
        links.append(contentsOf: newLinks)

        media.sort { $0.timestamp > $1.timestamp }
        docs.sort { $0.timestamp > $1.timestamp }
        links.sort { $0.date > $1.date }
    }
}

import SwiftUI
import UIKit
import SanchrShared

@MainActor
final class GalleryPageLoader: ObservableObject {
    struct PageState {
        var url: URL?
        var image: UIImage?
        var error: String?
        var isLoading = false

        static let empty = PageState()
    }

    typealias ImageDecoder = @Sendable (URL) async throws -> DecodedGalleryImage

    @Published private(set) var states: [String: PageState] = [:]

    private let resolveURL: @Sendable (String, Message.MediaAttachment) async throws -> URL
    private let decodeImage: ImageDecoder
    private var tasks: [String: Task<Void, Never>] = [:]

    init(
        resolver: ChatMediaResolving,
        decodeImage: @escaping ImageDecoder = GalleryPageLoader.defaultDecodeImage
    ) {
        self.resolveURL = { messageId, attachment in
            try await resolver.decryptedURL(
                forMessageId: messageId,
                attachment: attachment
            )
        }
        self.decodeImage = decodeImage
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
    }

    func updateWindow(items: [GalleryItem], centeredAt index: Int) {
        let validIndices = [index - 1, index, index + 1]
            .filter { items.indices.contains($0) }
        let wantedIDs = Set(validIndices.map { items[$0].id })

        cancelTasks(excluding: wantedIDs)

        for candidateIndex in validIndices {
            startLoading(items[candidateIndex])
        }
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    func retry(_ item: GalleryItem) {
        var state = states[item.id] ?? .empty
        state.error = nil
        states[item.id] = state
        startLoading(item, force: true)
    }

    func state(for item: GalleryItem) -> PageState {
        states[item.id] ?? .empty
    }

    func url(for item: GalleryItem) -> URL? {
        state(for: item).url
    }

    private func cancelTasks(excluding wantedIDs: Set<String>) {
        for (id, task) in tasks where !wantedIDs.contains(id) {
            task.cancel()
            tasks[id] = nil
        }
    }

    private func startLoading(_ item: GalleryItem, force: Bool = false) {
        guard let attachment = attachment(for: item) else { return }
        let current = states[item.id] ?? .empty

        if !force {
            let isReady = current.url != nil && (item.kind == .video || current.image != nil)
            if isReady || tasks[item.id] != nil {
                return
            }
        } else {
            tasks[item.id]?.cancel()
            tasks[item.id] = nil
        }

        var loadingState = current
        loadingState.isLoading = true
        loadingState.error = nil
        states[item.id] = loadingState

        tasks[item.id] = Task { [resolveURL, decodeImage] in
            do {
                let url = try await resolveURL(item.id, attachment)
                try Task.checkCancellation()

                let image: DecodedGalleryImage?
                if item.kind == .image {
                    image = try await decodeImage(url)
                } else {
                    image = nil
                }
                try Task.checkCancellation()

                tasks[item.id] = nil
                states[item.id] = PageState(
                    url: url,
                    image: image?.uiImage,
                    error: nil,
                    isLoading: false
                )
            } catch is CancellationError {
                tasks[item.id] = nil
                var state = states[item.id] ?? .empty
                state.isLoading = false
                states[item.id] = state
            } catch {
                tasks[item.id] = nil
                states[item.id] = PageState(
                    url: nil,
                    image: nil,
                    error: error.localizedDescription,
                    isLoading: false
                )
            }
        }
    }

    private func attachment(for item: GalleryItem) -> Message.MediaAttachment? {
        switch item.message.content {
        case .image(let attachment), .video(let attachment):
            return attachment
        default:
            return nil
        }
    }

    nonisolated static func defaultDecodeImage(url: URL) async throws -> DecodedGalleryImage {
        try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(contentsOfFile: url.path) else {
                throw GalleryPageLoaderError.decodeFailed
            }
            return DecodedGalleryImage(
                uiImage: image.preparingForDisplay() ?? image
            )
        }.value
    }
}

struct DecodedGalleryImage: @unchecked Sendable {
    let uiImage: UIImage
}

enum GalleryPageLoaderError: LocalizedError {
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .decodeFailed:
            return "Couldn't decode this image."
        }
    }
}

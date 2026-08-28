import XCTest
import UIKit
import SanchrShared
@testable import Sanchr

@MainActor
final class GalleryPageLoaderTests: XCTestCase {
    func test_updateWindow_prefetchesCurrentAndNeighbors() async throws {
        let resolver = GalleryLoaderResolver()
        let item0 = Self.makeGalleryItem(id: "img-0", kind: .image)
        let item1 = Self.makeGalleryItem(id: "img-1", kind: .image)
        let item2 = Self.makeGalleryItem(id: "vid-2", kind: .video)
        let image = try XCTUnwrap(UIImage(systemName: "photo"))

        let loader = GalleryPageLoader(
            resolver: resolver,
            decodeImage: { _ in DecodedGalleryImage(uiImage: image) }
        )

        loader.updateWindow(items: [item0, item1, item2], centeredAt: 1)

        try await waitUntil {
            loader.state(for: item0).image != nil &&
            loader.state(for: item1).image != nil &&
            loader.state(for: item2).url != nil
        }

        let resolvedIDs = await resolver.resolvedIDs().sorted()
        XCTAssertEqual(resolvedIDs, ["img-0", "img-1", "vid-2"])
    }

    func test_retry_reloadsAfterError() async throws {
        let resolver = GalleryLoaderResolver()
        let item = Self.makeGalleryItem(id: "img-retry", kind: .image)
        let image = try XCTUnwrap(UIImage(systemName: "photo"))
        let decodeAttempts = DecodeAttemptCounter()

        let loader = GalleryPageLoader(
            resolver: resolver,
            decodeImage: { _ in
                let attempt = await decodeAttempts.next()
                if attempt == 1 {
                    throw GalleryPageLoaderError.decodeFailed
                }
                return DecodedGalleryImage(uiImage: image)
            }
        )

        loader.updateWindow(items: [item], centeredAt: 0)

        try await waitUntil {
            loader.state(for: item).error != nil
        }

        loader.retry(item)

        try await waitUntil {
            loader.state(for: item).image != nil
        }

        XCTAssertNil(loader.state(for: item).error)
        let attemptCount = await decodeAttempts.value()
        XCTAssertEqual(attemptCount, 2)
    }

    func test_updateWindow_cancelsLoadsOutsideCurrentWindow() async throws {
        let resolver = HangingGalleryResolver()
        let loader = GalleryPageLoader(
            resolver: resolver,
            decodeImage: { _ in
                DecodedGalleryImage(
                    uiImage: try XCTUnwrap(UIImage(systemName: "photo"))
                )
            }
        )
        let items = (0..<5).map { index in
            Self.makeGalleryItem(id: "img-\(index)", kind: .image)
        }

        loader.updateWindow(items: items, centeredAt: 0)
        loader.updateWindow(items: items, centeredAt: 4)

        try await waitUntil {
            await resolver.wasCancelled("img-0")
        }
    }

    private static func makeGalleryItem(id: String, kind: GalleryItem.Kind) -> GalleryItem {
        let mimeType = kind == .image ? "image/jpeg" : "video/mp4"
        let content: Message.MessageContent = switch kind {
        case .image:
            .image(.init(Self.attachment(mimeType: mimeType)))
        case .video:
            .video(.init(Self.attachment(mimeType: mimeType)))
        }

        return GalleryItem(
            id: id,
            kind: kind,
            message: Message(
                id: id,
                conversationId: "conversation",
                senderId: "sender",
                timestamp: Date(),
                content: content,
                status: .sent,
                isOutgoing: false
            )
        )
    }

    private static func attachment(mimeType: String) -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://\(UUID().uuidString)")!,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: mimeType,
            sizeBytes: 1024
        )
    }
}

private actor GalleryLoaderResolver: ChatMediaResolving {
    private var resolvedMessageIDs: [String] = []

    func resolvedIDs() -> [String] {
        resolvedMessageIDs
    }

    func decryptedURL(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        resolvedMessageIDs.append(messageId)
        return URL(fileURLWithPath: "/tmp/\(messageId)")
    }

    func decryptedURLWithDisplayName(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        try await decryptedURL(forMessageId: messageId, attachment: attachment)
    }
}

private actor HangingGalleryResolver: ChatMediaResolving {
    private(set) var cancelledIDs: [String] = []

    func wasCancelled(_ id: String) -> Bool {
        cancelledIDs.contains(id)
    }

    func decryptedURL(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return URL(fileURLWithPath: "/tmp/\(messageId)")
        }, onCancel: {
            Task { await self.recordCancellation(messageId) }
        }
        )
    }

    func decryptedURLWithDisplayName(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        try await decryptedURL(forMessageId: messageId, attachment: attachment)
    }

    private func recordCancellation(_ id: String) {
        cancelledIDs.append(id)
    }
}

private actor DecodeAttemptCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }
    XCTFail("Timed out waiting for condition.")
}

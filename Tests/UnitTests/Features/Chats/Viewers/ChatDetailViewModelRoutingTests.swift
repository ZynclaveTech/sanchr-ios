import XCTest
import SanchrShared
@testable import Sanchr

/// Verifies that `ChatDetailViewModel.route(interaction:)` records each
/// incoming `MessageInteraction` so the bubble-tap spine in Phase 1 is
/// unit-testable without wiring up real coordinators.
@MainActor
final class ChatDetailViewModelRoutingTests: XCTestCase {

    func test_route_openMedia_seedsGalleryAndRecordsLastInteraction() {
        let vm = ChatDetailViewModel()
        vm.messages = [
            Self.makeImage(id: "img-1", timestamp: 100),
            Self.makeText(id: "txt-1", timestamp: 200),
            Self.makeVideo(id: "vid-1", timestamp: 300),
        ]

        var capturedSeed: GallerySeed?
        vm.route(
            interaction: .openMedia(messageId: "vid-1"),
            onOpenGallery: { seed in capturedSeed = seed }
        )

        XCTAssertEqual(vm.lastRoutedInteraction, .openMedia(messageId: "vid-1"))
        let seed = try! XCTUnwrap(capturedSeed)
        XCTAssertEqual(seed.items.map(\.id), ["img-1", "vid-1"])
        XCTAssertEqual(seed.initialIndex, 1)
    }

    func test_route_openMedia_forMissingMessage_suppressesGalleryCall() {
        let vm = ChatDetailViewModel()
        vm.messages = [Self.makeImage(id: "img-1", timestamp: 100)]

        var wasCalled = false
        vm.route(
            interaction: .openMedia(messageId: "nope"),
            onOpenGallery: { _ in wasCalled = true }
        )

        XCTAssertFalse(wasCalled)
        // lastRoutedInteraction is still updated — the routing itself
        // happened, the seed just couldn't be built.
        XCTAssertEqual(vm.lastRoutedInteraction, .openMedia(messageId: "nope"))
    }

    func test_route_openContact_forwardsNameAndPhone() {
        let vm = ChatDetailViewModel()
        var captured: (String, String)?
        vm.route(
            interaction: .openContact(name: "Alice", phoneNumber: "+15551234"),
            onOpenContact: { name, phone in captured = (name, phone) }
        )
        XCTAssertEqual(captured?.0, "Alice")
        XCTAssertEqual(captured?.1, "+15551234")
        XCTAssertEqual(vm.lastRoutedInteraction,
                       .openContact(name: "Alice", phoneNumber: "+15551234"))
    }

    func test_route_openLocation_forwardsCoordinates() {
        let vm = ChatDetailViewModel()
        var captured: (Double, Double)?
        vm.route(
            interaction: .openLocation(latitude: 12.9716, longitude: 77.5946),
            onOpenLocation: { lat, lon in captured = (lat, lon) }
        )
        XCTAssertEqual(captured?.0, 12.9716)
        XCTAssertEqual(captured?.1, 77.5946)
        XCTAssertEqual(vm.lastRoutedInteraction,
                       .openLocation(latitude: 12.9716, longitude: 77.5946))
    }

    func test_route_openDocument_forwardsMessageId() {
        let vm = ChatDetailViewModel()
        var capturedId: String?
        vm.route(
            interaction: .openDocument(messageId: "doc-1"),
            onOpenDocument: { id in capturedId = id }
        )
        XCTAssertEqual(capturedId, "doc-1")
        XCTAssertEqual(vm.lastRoutedInteraction, .openDocument(messageId: "doc-1"))
    }

    // MARK: - galleryItems(forTappedMessageId:) direct coverage

    func test_galleryItems_returnsOnlyMediaInChronologicalOrder() {
        let vm = ChatDetailViewModel()
        vm.messages = [
            Self.makeText(id: "t1", timestamp: 100),
            Self.makeImage(id: "i1", timestamp: 200),
            Self.makeText(id: "t2", timestamp: 300),
            Self.makeVideo(id: "v1", timestamp: 400),
            Self.makeImage(id: "i2", timestamp: 500),
        ]

        let seed = try! XCTUnwrap(vm.galleryItems(forTappedMessageId: "v1"))

        XCTAssertEqual(seed.items.map(\.id), ["i1", "v1", "i2"])
        XCTAssertEqual(seed.items.map(\.kind), [.image, .video, .image])
        XCTAssertEqual(seed.initialIndex, 1)
    }

    func test_galleryItems_returnsNilWhenTappedMessageIsText() {
        let vm = ChatDetailViewModel()
        vm.messages = [Self.makeText(id: "t1", timestamp: 100)]
        XCTAssertNil(vm.galleryItems(forTappedMessageId: "t1"))
    }

    // MARK: - Builders

    private static func makeText(id: String, timestamp: TimeInterval) -> Message {
        Message(
            id: id,
            conversationId: "c",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: timestamp),
            content: .text("hello"),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func makeImage(id: String, timestamp: TimeInterval) -> Message {
        Message(
            id: id,
            conversationId: "c",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: timestamp),
            content: .image(Self.attachment(mime: "image/jpeg")),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func makeVideo(id: String, timestamp: TimeInterval) -> Message {
        Message(
            id: id,
            conversationId: "c",
            senderId: "s",
            timestamp: Date(timeIntervalSince1970: timestamp),
            content: .video(Self.attachment(mime: "video/mp4")),
            status: .sent,
            isOutgoing: false
        )
    }

    private static func attachment(mime: String) -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://x")!,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: mime,
            sizeBytes: 0
        )
    }
}

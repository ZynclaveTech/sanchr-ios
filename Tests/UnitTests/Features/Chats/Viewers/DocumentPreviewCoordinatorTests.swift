import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class DocumentPreviewCoordinatorTests: XCTestCase {
    func test_open_setsPresentationOnSuccess() async {
        let expectedURL = URL(fileURLWithPath: "/tmp/document.pdf")
        let resolver = MockChatMediaResolver(
            namedURLResult: .success(expectedURL)
        )
        let message = Self.makeDocumentMessage(id: "doc-1")
        let coordinator = DocumentPreviewCoordinator(
            resolver: resolver,
            messageLookup: { id in
                id == "doc-1" ? message : nil
            }
        )

        await coordinator.open(messageId: "doc-1")

        XCTAssertEqual(coordinator.presentation?.fileURL, expectedURL)
        XCTAssertFalse(coordinator.isResolving)
        XCTAssertNil(coordinator.resolveError)
    }

    func test_open_setsErrorWhenMessageMissing() async {
        let coordinator = DocumentPreviewCoordinator(
            resolver: MockChatMediaResolver(namedURLResult: .success(URL(fileURLWithPath: "/tmp/x"))),
            messageLookup: { _ in nil }
        )

        await coordinator.open(messageId: "missing")

        XCTAssertNil(coordinator.presentation)
        XCTAssertEqual(coordinator.resolveError, "Attachment not found.")
        XCTAssertFalse(coordinator.isResolving)
    }

    func test_open_setsErrorWhenResolverFails() async {
        let resolver = MockChatMediaResolver(
            namedURLResult: .failure(TestError.failed)
        )
        let message = Self.makeDocumentMessage(id: "doc-2")
        let coordinator = DocumentPreviewCoordinator(
            resolver: resolver,
            messageLookup: { id in
                id == "doc-2" ? message : nil
            }
        )

        await coordinator.open(messageId: "doc-2")

        XCTAssertNil(coordinator.presentation)
        XCTAssertEqual(coordinator.resolveError, TestError.failed.localizedDescription)
        XCTAssertFalse(coordinator.isResolving)
    }

    private static func makeDocumentMessage(id: String) -> Message {
        Message(
            id: id,
            conversationId: "conversation",
            senderId: "sender",
            timestamp: Date(),
            content: .document(.init(
                Message.MediaAttachment(
                    url: URL(string: "sanchr-media://\(id)")!,
                    encryptionKey: Data(),
                    encryptionIV: Data(),
                    mimeType: "application/pdf",
                    sizeBytes: 1024
                )
            )),
            status: .sent,
            isOutgoing: false
        )
    }
}

private final class MockChatMediaResolver: ChatMediaResolving, @unchecked Sendable {
    let namedURLResult: Result<URL, Error>

    init(namedURLResult: Result<URL, Error>) {
        self.namedURLResult = namedURLResult
    }

    func decryptedURL(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        try namedURLResult.get()
    }

    func decryptedURLWithDisplayName(
        forMessageId messageId: String,
        attachment: Message.MediaAttachment
    ) async throws -> URL {
        try namedURLResult.get()
    }
}

private enum TestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Resolver failed."
    }
}

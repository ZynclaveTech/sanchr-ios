import Foundation
import XCTest
@testable import Sanchr

final class AppRouterTests: XCTestCase {
    @MainActor
    func testConsumePendingChatAttachmentClearsAfterSingleRead() {
        let router = AppRouter()
        let capture = CapturedMedia(
            kind: .photo,
            data: Data([0x01, 0x02, 0x03]),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            width: 640,
            height: 480,
            durationSeconds: nil
        )

        router.deepLinkToConversation(
            conversationId: "conversation-1",
            pendingAttachment: .capturedMedia(capture)
        )

        let firstConsume = router.consumePendingChatAttachment(for: "conversation-1")
        switch firstConsume {
        case .capturedMedia(let consumed):
            XCTAssertEqual(consumed, capture)
        default:
            XCTFail("Expected captured media attachment")
        }

        XCTAssertNil(router.consumePendingChatAttachment(for: "conversation-1"))
    }
}

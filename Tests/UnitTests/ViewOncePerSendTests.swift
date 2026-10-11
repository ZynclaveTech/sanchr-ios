import SanchrShared
import XCTest

@testable import Sanchr

/// View-once used to be a setting on the whole chat. It can now be chosen
/// for one send.
@MainActor
final class ViewOncePerSendTests: XCTestCase {

    private func item(video: Bool = false) -> BatchMediaItem {
        BatchMediaItem(
            kind: video ? .video(durationSeconds: 3) : .photo,
            fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg"),
            sizeBytes: 10)
    }

    private func policy(viewOnce: Bool) -> ChatVaultPolicy {
        ChatVaultPolicy(
            conversationId: "c1", autoVaultIncoming: false, viewOnceOutgoing: viewOnce, screenshotProtection: false)
    }

    func testOnePhotoCanBeSentViewOnce() {
        let model = MediaBatchReviewModel(items: [item()])
        XCTAssertTrue(model.canSendViewOnce)
        XCTAssertFalse(model.viewOnce, "off until chosen")

        model.viewOnce = true

        XCTAssertTrue(model.viewOnce)
        XCTAssertEqual(model.itemsToSend.map(\.isViewOnce), [true])
        XCTAssertEqual(model.itemsToSend.first?.sendableAttachment().isViewOnce, true)
    }

    func testAVideoCanToo() {
        let model = MediaBatchReviewModel(items: [item(video: true)])

        model.viewOnce = true

        XCTAssertEqual(model.itemsToSend.first?.sendableAttachment().isViewOnce, true)
    }

    /// Left alone, nothing about an ordinary send changes.
    func testAnOrdinarySendCarriesNoViewOnceMark() {
        let model = MediaBatchReviewModel(items: [item()])

        XCTAssertEqual(model.itemsToSend.map(\.isViewOnce), [false])
        XCTAssertNil(model.itemsToSend.first?.sendableAttachment().isViewOnce)
    }

    func testSeveralItemsAreNeverViewOnce() {
        let model = MediaBatchReviewModel(items: [item(), item()])
        XCTAssertFalse(model.canSendViewOnce)

        model.viewOnce = true

        XCTAssertFalse(model.viewOnce)
        XCTAssertEqual(model.itemsToSend.map(\.isViewOnce), [false, false])
    }

    /// Removing down to one must not switch on something chosen when it
    /// could not apply.
    func testRemovingDownToOneDoesNotTurnItOnBehindTheUsersBack() {
        let first = item()
        let second = item()
        let model = MediaBatchReviewModel(items: [first, second])
        model.viewOnce = true

        model.remove(id: second.id)

        XCTAssertTrue(model.canSendViewOnce)
        XCTAssertFalse(model.viewOnce)
        XCTAssertEqual(model.itemsToSend.map(\.isViewOnce), [false])
    }

    func testTurningItOffAgainSendsNormally() {
        let model = MediaBatchReviewModel(items: [item()])
        model.viewOnce = true
        model.viewOnce = false

        XCTAssertEqual(model.itemsToSend.map(\.isViewOnce), [false])
    }

    // MARK: - What the sender stamps

    private func attachment(viewOnce: Bool?) -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(fileURLWithPath: "/tmp/a.jpg"), encryptionKey: Data(), encryptionIV: Data(),
            mimeType: "image/jpeg", sizeBytes: 1, isViewOnce: viewOnce)
    }

    func testAMarkedSendIsViewOnceInAChatWhosePolicyIsOff() {
        XCTAssertTrue(MessageSender.sendsViewOnce(policy: policy(viewOnce: false), attachment: attachment(viewOnce: true)))
    }

    func testTheChatsPolicyStillMakesEverySendViewOnce() {
        XCTAssertTrue(MessageSender.sendsViewOnce(policy: policy(viewOnce: true), attachment: attachment(viewOnce: nil)))
        XCTAssertTrue(MessageSender.sendsViewOnce(policy: policy(viewOnce: true), attachment: attachment(viewOnce: false)))
    }

    func testNeitherMeansAnOrdinarySend() {
        XCTAssertFalse(MessageSender.sendsViewOnce(policy: policy(viewOnce: false), attachment: attachment(viewOnce: nil)))
        XCTAssertFalse(MessageSender.sendsViewOnce(policy: policy(viewOnce: false), attachment: attachment(viewOnce: false)))
    }
}

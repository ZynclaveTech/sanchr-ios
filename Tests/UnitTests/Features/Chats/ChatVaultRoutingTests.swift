import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class ChatVaultRoutingTests: XCTestCase {

    func test_isVaultEligible_returnsTrueForMedia() {
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.image(.init(Self.attachment("image/jpeg")))))
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.video(.init(Self.attachment("video/mp4")))))
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.audio(.init(Self.attachment("audio/m4a")))))
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.document(.init(Self.attachment("application/pdf")))))
    }

    func test_isVaultEligible_returnsFalseForText() {
        XCTAssertFalse(MessageRepositoryImpl.isVaultEligibleContent(.text("hi")))
    }

    func test_isVaultEligible_returnsFalseForSystem() {
        XCTAssertFalse(MessageRepositoryImpl.isVaultEligibleContent(.system(.identityKeyChanged)))
    }

    // MARK: - What the vault must leave alone

    func test_isVaultEligible_trueForAnOrdinaryReceivedPhoto() {
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligible(Self.message(.image(.init(Self.attachment("image/jpeg"))))))
    }

    /// View-once media was shown once on purpose; vaulting it keeps it for good.
    func test_isVaultEligible_falseForViewOnce() {
        let once = Self.attachment("image/jpeg", viewOnce: true)
        XCTAssertFalse(MessageRepositoryImpl.isVaultEligible(Self.message(.image(.init(once)))))
    }

    func test_isVaultEligible_falseForDisappearing() {
        let timed = Self.message(.image(.init(Self.attachment("image/jpeg"))), expiresAt: Date().addingTimeInterval(60))
        XCTAssertFalse(MessageRepositoryImpl.isVaultEligible(timed))
    }

    /// The message becomes one tombstone, so it cannot be half moved.
    func test_isVaultEligible_falseForAnAlbumWithOneViewOnceItem() {
        let album = Message.MediaAttachments([
            Self.attachment("image/jpeg"), Self.attachment("image/jpeg", viewOnce: true),
        ])
        XCTAssertFalse(MessageRepositoryImpl.isVaultEligible(Self.message(.image(album))))
    }

    func test_isVaultEligible_falseForText() {
        XCTAssertFalse(MessageRepositoryImpl.isVaultEligible(Self.message(.text("hi"))))
    }

    // MARK: - Albums

    /// `media.first` used to be vaulted and the whole message tombstoned.
    func test_attachmentsFromContent_returnsEveryItemOfAnAlbum() {
        let album = Message.MediaAttachments([
            Self.attachment("image/jpeg"), Self.attachment("video/mp4"), Self.attachment("image/png"),
        ])
        XCTAssertEqual(MessageRepositoryImpl.attachmentsFromContent(.image(album)).count, 3)
        XCTAssertTrue(MessageRepositoryImpl.attachmentsFromContent(.text("hi")).isEmpty)
    }

    func test_vaultCacheId_matchesTheAlbumBubbleKeys() {
        XCTAssertEqual(MessageRepositoryImpl.vaultCacheId(messageId: "m1", index: 0, count: 1), "m1")
        XCTAssertEqual(MessageRepositoryImpl.vaultCacheId(messageId: "m1", index: 0, count: 3), "m1#0")
        XCTAssertEqual(MessageRepositoryImpl.vaultCacheId(messageId: "m1", index: 2, count: 3), "m1#2")
    }

    func test_vaultItemType_followsEachItemsOwnType() {
        XCTAssertEqual(MessageRepositoryImpl.vaultItemType(forMimeType: "image/jpeg"), .photo)
        XCTAssertEqual(MessageRepositoryImpl.vaultItemType(forMimeType: "video/mp4"), .video)
        XCTAssertEqual(MessageRepositoryImpl.vaultItemType(forMimeType: "audio/m4a"), .audio)
        XCTAssertEqual(MessageRepositoryImpl.vaultItemType(forMimeType: "application/pdf"), .document)
    }

    private static func message(_ content: Message.MessageContent, expiresAt: Date? = nil) -> Message {
        Message(
            id: "m1",
            conversationId: "c1",
            senderId: "peer",
            timestamp: Date(),
            content: content,
            status: .delivered,
            isOutgoing: false,
            expiresAt: expiresAt
        )
    }

    private static func attachment(_ mime: String, viewOnce: Bool? = nil) -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://x")!,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: mime,
            sizeBytes: 0,
            isViewOnce: viewOnce
        )
    }
}

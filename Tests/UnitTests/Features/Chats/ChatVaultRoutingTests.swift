import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class ChatVaultRoutingTests: XCTestCase {

    func test_isVaultEligible_returnsTrueForMedia() {
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.image(Self.attachment("image/jpeg"))))
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.video(Self.attachment("video/mp4"))))
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.audio(Self.attachment("audio/m4a"))))
        XCTAssertTrue(MessageRepositoryImpl.isVaultEligibleContent(.document(Self.attachment("application/pdf"))))
    }

    func test_isVaultEligible_returnsFalseForText() {
        XCTAssertFalse(MessageRepositoryImpl.isVaultEligibleContent(.text("hi")))
    }

    func test_isVaultEligible_returnsFalseForSystem() {
        XCTAssertFalse(MessageRepositoryImpl.isVaultEligibleContent(.system(.identityKeyChanged)))
    }

    private static func attachment(_ mime: String) -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "sanchr-media://x")!,
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: mime,
            sizeBytes: 0
        )
    }
}

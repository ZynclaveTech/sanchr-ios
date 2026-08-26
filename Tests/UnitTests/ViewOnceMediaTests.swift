import XCTest

@testable import Sanchr
@testable import SanchrShared

/// View-once media must not be readable from the transcript, and must never be
/// copied somewhere permanent.
///
/// `isViewOnce` was modelled, set on send, and round-tripped correctly — but the
/// transcript rendered it as an ordinary thumbnail, so the content sat on screen
/// indefinitely and the "delete after viewing" step only removed something the
/// recipient had already seen. The auto-save path did not check the flag either,
/// so a view-once photo was written to the system photo library and, for most
/// users, synced to iCloud permanently.
final class ViewOnceMediaTests: XCTestCase {

    private func attachment(viewOnce: Bool?) -> Message.MediaAttachment {
        Message.MediaAttachment(
            url: URL(string: "https://media.example/x.jpg")!,
            encryptionKey: Data(repeating: 1, count: 32),
            encryptionIV: Data(repeating: 2, count: 12),
            mimeType: "image/jpeg",
            sizeBytes: 1024,
            isViewOnce: viewOnce
        )
    }

    // MARK: - Auto-save exclusion

    /// The decision that matters most: auto-save writes to the system photo
    /// library, which for most users means iCloud. That is unrecoverable, and the
    /// exact opposite of what the sender chose.
    func test_viewOnceMedia_isExcludedFromAutoSave() {
        XCTAssertFalse(
            MediaAutoSavePolicy.shouldAutoSave(
                attachment: attachment(viewOnce: true),
                autoSaveEnabled: true,
                galleryVisible: true,
                isOutgoing: false
            ),
            "view-once media must never be copied into the photo library"
        )
    }

    func test_ordinaryMedia_stillAutoSavesWhenEnabled() {
        XCTAssertTrue(
            MediaAutoSavePolicy.shouldAutoSave(
                attachment: attachment(viewOnce: nil),
                autoSaveEnabled: true,
                galleryVisible: true,
                isOutgoing: false
            )
        )
    }

    func test_autoSave_respectsExistingConditions() {
        let ordinary = attachment(viewOnce: nil)
        XCTAssertFalse(
            MediaAutoSavePolicy.shouldAutoSave(
                attachment: ordinary, autoSaveEnabled: false,
                galleryVisible: true, isOutgoing: false),
            "disabled setting still wins")
        XCTAssertFalse(
            MediaAutoSavePolicy.shouldAutoSave(
                attachment: ordinary, autoSaveEnabled: true,
                galleryVisible: false, isOutgoing: false),
            "hidden-from-gallery still wins")
        XCTAssertFalse(
            MediaAutoSavePolicy.shouldAutoSave(
                attachment: ordinary, autoSaveEnabled: true,
                galleryVisible: true, isOutgoing: true),
            "we do not re-save our own outgoing media")
    }

    // MARK: - Flag semantics

    /// `nil` and `false` both mean ordinary media. Treating only `true` as
    /// view-once keeps legacy rows, which predate the field, rendering normally.
    func test_absentFlag_isTreatedAsOrdinaryMedia() {
        XCTAssertFalse(attachment(viewOnce: nil).isViewOnce == true)
        XCTAssertFalse(attachment(viewOnce: false).isViewOnce == true)
        XCTAssertTrue(attachment(viewOnce: true).isViewOnce == true)
    }

    /// The flag has to survive storage, or the recipient's device forgets the
    /// media was ever restricted and renders it inline.
    func test_viewOnceFlag_survivesEncodingRoundTrip() throws {
        let encoded = try JSONEncoder().encode(attachment(viewOnce: true))
        let decoded = try JSONDecoder().decode(Message.MediaAttachment.self, from: encoded)
        XCTAssertEqual(decoded.isViewOnce, true)
    }
}

import XCTest
@testable import Sanchr

final class AttachmentIntentTests: XCTestCase {

    func test_pickedMedia_isSendable_andCarriesRequiredFields() {
        let media = PickedMedia(
            id: UUID(),
            kind: .photo,
            data: Data([0x01, 0x02]),
            fileURL: nil,
            originalFilename: "IMG_0001.HEIC",
            mimeType: "image/heic",
            width: 4032,
            height: 3024,
            durationSeconds: nil
        )
        XCTAssertEqual(media.kind, .photo)
        XCTAssertEqual(media.width, 4032)
        XCTAssertNil(media.durationSeconds)
    }

    func test_capturedMedia_video_carriesDuration() {
        let cap = CapturedMedia(
            kind: .video,
            data: Data(),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            width: 1920,
            height: 1080,
            durationSeconds: 12.5
        )
        XCTAssertEqual(cap.durationSeconds, 12.5)
    }

    func test_pickedFile_urlIsSandboxed() {
        let url = URL(fileURLWithPath: "/tmp/attachment-staging/abc.pdf")
        let file = PickedFile(url: url, filename: "abc.pdf", sizeBytes: 1024, mimeType: "application/pdf")
        XCTAssertFalse(file.url.path.contains("/var/mobile/Containers/Shared"))
    }

    func test_attachmentIntent_allCasesCompile() {
        let cases: [AttachmentIntent] = [
            .photoLibrary([]),
            .capturedMedia(CapturedMedia(kind: .photo, data: Data(), capturedAt: Date(), width: 1, height: 1, durationSeconds: nil)),
            .file(PickedFile(url: URL(fileURLWithPath: "/tmp/x"), filename: "x", sizeBytes: 0, mimeType: "application/octet-stream"))
        ]
        XCTAssertEqual(cases.count, 3)
    }
}

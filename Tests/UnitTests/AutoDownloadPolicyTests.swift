import XCTest
import SanchrShared

@testable import Sanchr

/// The auto-download pickers were synced to the server but never enforced, so
/// these cover the decision table that now backs them.
final class AutoDownloadPolicyTests: XCTestCase {

    private func decide(
        _ mime: String,
        on connection: NetworkMonitor.ConnectionType,
        wifi: String = "all",
        mobile: String = "all"
    ) -> AutoDownloadPolicy.Decision {
        AutoDownloadPolicy.decision(
            mimeType: mime,
            connection: connection,
            wifi: wifi,
            mobile: mobile
        )
    }

    func testMediaClassification() {
        XCTAssertEqual(AutoDownloadPolicy.mediaClass(forMimeType: "image/jpeg"), .photo)
        XCTAssertEqual(AutoDownloadPolicy.mediaClass(forMimeType: "IMAGE/HEIC"), .photo)
        XCTAssertEqual(AutoDownloadPolicy.mediaClass(forMimeType: "video/mp4"), .video)
        XCTAssertEqual(AutoDownloadPolicy.mediaClass(forMimeType: "audio/m4a"), .voiceNote)
        XCTAssertEqual(AutoDownloadPolicy.mediaClass(forMimeType: "application/pdf"), .document)
    }

    func testAllTierDownloadsEverything() {
        XCTAssertEqual(decide("video/mp4", on: .cellular, mobile: "all"), .automatic)
        XCTAssertEqual(decide("application/pdf", on: .cellular, mobile: "all"), .automatic)
    }

    /// "Photos only" covers images and voice notes — voice notes are seconds of
    /// AAC — but not video or documents, which are the expensive payloads.
    func testPhotosTierAllowsImagesAndVoiceNotesOnly() {
        XCTAssertEqual(decide("image/jpeg", on: .cellular, mobile: "photos"), .automatic)
        XCTAssertEqual(decide("audio/m4a", on: .cellular, mobile: "photos"), .automatic)
        XCTAssertEqual(decide("video/mp4", on: .cellular, mobile: "photos"), .manual)
        XCTAssertEqual(decide("application/pdf", on: .cellular, mobile: "photos"), .manual)
    }

    func testNoneTierDefersEverything() {
        XCTAssertEqual(decide("image/jpeg", on: .cellular, mobile: "none"), .manual)
        XCTAssertEqual(decide("audio/m4a", on: .cellular, mobile: "none"), .manual)
    }

    /// The regression that started this: a restrictive mobile setting must not
    /// leak into Wi-Fi, and a restrictive Wi-Fi setting must not leak into
    /// cellular.
    func testEachConnectionUsesItsOwnSetting() {
        XCTAssertEqual(decide("video/mp4", on: .wifi, wifi: "all", mobile: "none"), .automatic)
        XCTAssertEqual(decide("video/mp4", on: .cellular, wifi: "all", mobile: "none"), .manual)
        XCTAssertEqual(decide("video/mp4", on: .wiredEthernet, wifi: "none", mobile: "all"), .manual)
    }

    /// Offline there is nothing to authorise: the fetch fails on its own, and
    /// reporting `.manual` would strand a "Tap to download" badge on a bubble
    /// the moment connectivity returned.
    func testOfflineDoesNotDefer() {
        XCTAssertEqual(decide("video/mp4", on: NetworkMonitor.ConnectionType.none, mobile: "none"), .automatic)
    }

    /// An unrecognised tier (an older or newer build writing a value we do not
    /// know) must not silently block every download.
    func testUnknownTierFallsBackToAll() {
        XCTAssertEqual(decide("video/mp4", on: .cellular, mobile: "surprise"), .automatic)
    }
}

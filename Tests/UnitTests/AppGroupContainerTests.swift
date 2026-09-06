import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// The shared container has to resolve for the suite to run at all.
///
/// `AppGroup.containerURL` traps when the App Group entitlement is missing,
/// which is right for a shipped build and fatal for CI: the entitlement needs
/// a provisioning profile, which needs a signing identity, which a fork pull
/// request cannot be given. The suite died before its first assertion, so
/// every test here guarded nothing except on a developer's own machine.
///
/// It now falls back to a temporary directory when XCTest is hosting the
/// process. These tests are what keeps that fallback honest — if it regresses,
/// the whole suite stops running rather than reporting one failure, so the
/// signal is worth naming explicitly.
final class AppGroupContainerTests: XCTestCase {

    func testContainerResolves() {
        XCTAssertFalse(AppGroup.containerURL.path.isEmpty)
    }

    /// Resolving is not enough — the database and media caches are written
    /// through this URL, so a path that exists but cannot be written to would
    /// fail later and further away.
    func testContainerIsWritable() throws {
        let probe = AppGroup.containerURL.appendingPathComponent("write-probe-\(UUID().uuidString)")
        try Data([0x01]).write(to: probe)
        defer { try? FileManager.default.removeItem(at: probe) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.path))
    }

    /// The derived URLs create their own directories, and a caller that got a
    /// path whose parent did not exist would only find out on first write.
    func testDerivedPathsAreCreated() {
        for url in [AppGroup.databaseURL.deletingLastPathComponent(), AppGroup.mediaCacheURL] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                "\(url.lastPathComponent) was not created"
            )
            XCTAssertTrue(isDirectory.boolValue, "\(url.lastPathComponent) is not a directory")
        }
    }

    /// Every caller must see the same container: the share extension and the
    /// app read each other's writes through it, and a per-call temporary
    /// directory would pass a naive existence check while silently splitting
    /// their state.
    func testContainerIsStableAcrossCalls() {
        XCTAssertEqual(AppGroup.containerURL, AppGroup.containerURL)
    }
}

import Foundation
import XCTest
import SanchrShared

/// Unit tests for `AppGroupMigration`.
///
/// These tests deliberately avoid `AppGroup.userDefaults`, `AppGroup.databaseURL`,
/// and `AppGroupMigration.legacyDatabaseURL` — those resolve to real on-disk
/// locations and would contaminate the developer's actual database / shared
/// container. Instead they exercise the test seam
/// `AppGroupMigration.performMigration(legacyDatabaseURL:targetDatabaseURL:defaults:)`
/// against a per-test temporary directory and a per-test `UserDefaults` suite.
final class AppGroupMigrationTests: XCTestCase {

    private var tempRoot: URL!
    private var legacyDir: URL!
    private var targetDir: URL!
    private var legacyDB: URL!
    private var targetDB: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    private var flagKey: String { AppGroupMigration.migrationFlagKeyForTesting }

    override func setUpWithError() throws {
        try super.setUpWithError()

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppGroupMigrationTests-\(UUID().uuidString)", isDirectory: true)
        legacyDir = tempRoot.appendingPathComponent("legacy", isDirectory: true)
        targetDir = tempRoot.appendingPathComponent("appgroup", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        // Note: do NOT pre-create targetDir — the migration must handle that.

        legacyDB = legacyDir.appendingPathComponent("sanchr.sqlite")
        targetDB = targetDir.appendingPathComponent("sanchr.sqlite")

        suiteName = "test.AppGroupMigration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "Failed to create isolated UserDefaults suite")
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        defaults = nil
        suiteName = nil
        tempRoot = nil
        legacyDir = nil
        targetDir = nil
        legacyDB = nil
        targetDB = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)!.write(to: url)
    }

    private func runMigration() {
        AppGroupMigration.performMigration(
            legacyDatabaseURL: legacyDB,
            targetDatabaseURL: targetDB,
            defaults: defaults
        )
    }

    // MARK: - Tests

    func test_happyPath_copiesDatabase_andSetsFlag() throws {
        let payload = "primary-db-bytes-\(UUID().uuidString)"
        try write(payload, to: legacyDB)

        runMigration()

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDB.path))
        let copied = try Data(contentsOf: targetDB)
        XCTAssertEqual(copied, payload.data(using: .utf8))
        XCTAssertTrue(defaults.bool(forKey: flagKey))
        // Source must remain (we copy, never move).
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDB.path))
    }

    func test_happyPath_copiesWalAndShmSidecars() throws {
        try write("db", to: legacyDB)
        let legacyWal = legacyDB.appendingPathExtension("wal")
        let legacyShm = legacyDB.appendingPathExtension("shm")
        try write("wal-bytes", to: legacyWal)
        try write("shm-bytes", to: legacyShm)

        runMigration()

        let targetWal = targetDB.appendingPathExtension("wal")
        let targetShm = targetDB.appendingPathExtension("shm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetWal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetShm.path))
        XCTAssertEqual(try Data(contentsOf: targetWal), "wal-bytes".data(using: .utf8))
        XCTAssertEqual(try Data(contentsOf: targetShm), "shm-bytes".data(using: .utf8))
        XCTAssertTrue(defaults.bool(forKey: flagKey))
    }

    func test_idempotent_secondRunIsNoOp() throws {
        try write("v1", to: legacyDB)

        runMigration()
        XCTAssertTrue(defaults.bool(forKey: flagKey))

        // Mutate the destination AFTER the first run. A second run must
        // NOT touch it (the flag short-circuits before any FS work).
        try write("mutated", to: targetDB)

        runMigration()

        XCTAssertEqual(try Data(contentsOf: targetDB), "mutated".data(using: .utf8))
    }

    func test_destinationAlreadyExists_doesNotOverwrite_setsFlag() throws {
        try write("legacy-bytes", to: legacyDB)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try write("preexisting", to: targetDB)

        runMigration()

        // Destination preserved.
        XCTAssertEqual(try Data(contentsOf: targetDB), "preexisting".data(using: .utf8))
        // Flag set so we don't loop forever.
        XCTAssertTrue(defaults.bool(forKey: flagKey))
    }

    func test_noLegacyFile_isCleanInstall_setsFlag() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDB.path))

        runMigration()

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDB.path))
        XCTAssertTrue(defaults.bool(forKey: flagKey))
    }

    func test_targetDirectoryCreationFails_doesNotCrash_leavesFlagUnsetForRetry() throws {
        // Force the "create target directory" step to fail by planting a
        // regular file at the exact path the migration will try to use as
        // the target's parent directory. `createDirectory(...)` will then
        // throw NSFileWriteFileExistsError, the migration must catch it,
        // log, return, and leave the flag UNSET so the next launch retries.
        try write("legacy", to: legacyDB)

        // `targetDir` here corresponds to `target.deletingLastPathComponent()`
        // inside the migration. Plant a file there.
        try write("not-a-directory", to: targetDir)

        // Must not crash / throw.
        runMigration()

        XCTAssertFalse(
            defaults.bool(forKey: flagKey),
            "Migration must leave the flag unset on a failed copy so the next launch retries"
        )
        // Destination DB was never written.
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDB.path))
        // Legacy source intact (we copy, never move).
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDB.path))
    }
}

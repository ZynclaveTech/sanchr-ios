import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// The settings screens push the whole settings row on every change, and the
/// server replaces the row. These tests pin down what may and may not reach
/// the server: never the hardcoded defaults, never an echo of what the server
/// just sent, and never a loop after a failure.
@MainActor
final class SettingsViewModelSyncTests: XCTestCase {

    private final class FakeSettingsDataSource: SettingsDataSourceProtocol, @unchecked Sendable {
        var stored = Sanchr_Settings_UserSettings()
        var loadFails = false
        var updateFails = false
        var toggleFails = false
        private(set) var updateCalls: [Sanchr_Settings_UserSettings] = []
        private(set) var toggleCalls: [Bool] = []

        struct Failure: Error {}

        func getSettings() async throws -> Sanchr_Settings_UserSettings {
            if loadFails { throw Failure() }
            return stored
        }

        func updateSettings(settings: Sanchr_Settings_UserSettings) async throws -> Sanchr_Settings_UserSettings {
            updateCalls.append(settings)
            if updateFails { throw Failure() }
            stored = settings
            return settings
        }

        func toggleSanchrMode(enabled: Bool) async throws -> Sanchr_Settings_UserSettings {
            toggleCalls.append(enabled)
            if toggleFails { throw Failure() }
            stored.sanchrModeEnabled = enabled
            return stored
        }
    }

    private var source: FakeSettingsDataSource!
    private var viewModel: SettingsViewModel!
    private var cache: PrivacySettingsCache!

    override func setUp() {
        super.setUp()
        source = FakeSettingsDataSource()
        // Not the view model's defaults, so an echo of the defaults is visible.
        source.stored.readReceipts = true
        source.stored.typingIndicator = true
        source.stored.theme = "dark"
        source.stored.autoDownloadWifi = "photos"
        viewModel = SettingsViewModel()
        cache = PrivacySettingsCache()
    }

    private func load() async {
        await viewModel.loadSettings(settingsDataSource: source, privacySettings: cache)
    }

    /// The debounce is 0.5 s on the main queue.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(800))
    }

    // MARK: - Load failure

    /// The bug: with the load failed and the fields at their defaults, the
    /// first toggle the user touched pushed every default over the server row.
    func testAFailedLoadNeverPushesTheDefaults() async throws {
        source.loadFails = true
        await load()
        XCTAssertFalse(viewModel.hasLoadedSettings)
        XCTAssertNotNil(viewModel.errorMessage)

        viewModel.onlineStatusVisible = true
        viewModel.debouncedSync(settingsDataSource: source)
        try await settle()

        XCTAssertTrue(source.updateCalls.isEmpty, "nothing may be pushed until a load has succeeded")
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testSanchrModeBeforeALoadIsRefused() async {
        source.loadFails = true
        await load()

        viewModel.sanchrModeEnabled = true
        await viewModel.setSanchrMode(enabled: true, settingsDataSource: source)

        XCTAssertTrue(source.toggleCalls.isEmpty)
        XCTAssertFalse(viewModel.sanchrModeEnabled)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    // MARK: - Echo

    /// Hydrating the fields fires every toggle's onChange, each of which calls
    /// debouncedSync. None of that is a user edit.
    func testHydrationDoesNotEchoBackToTheServer() async throws {
        await load()
        XCTAssertTrue(viewModel.readReceipts)

        viewModel.debouncedSync(settingsDataSource: source)
        try await settle()

        XCTAssertTrue(source.updateCalls.isEmpty)
    }

    func testAnEditIsPushedOnceAndBecomesTheBaseline() async throws {
        await load()

        viewModel.readReceipts = false
        viewModel.debouncedSync(settingsDataSource: source)
        try await settle()
        XCTAssertEqual(source.updateCalls.count, 1)
        XCTAssertFalse(source.updateCalls[0].readReceipts)
        XCTAssertTrue(source.updateCalls[0].typingIndicator, "untouched fields carry the loaded value, not the default")

        // The confirmation re-applies the fields and fires onChange again.
        viewModel.debouncedSync(settingsDataSource: source)
        try await settle()
        XCTAssertEqual(source.updateCalls.count, 1, "the confirmed state must not be pushed a second time")
    }

    // MARK: - Failure

    func testAFailedPushRevertsTheToggleAndReportsIt() async throws {
        await load()
        source.updateFails = true

        viewModel.readReceipts = false
        viewModel.debouncedSync(settingsDataSource: source)
        try await settle()

        XCTAssertTrue(viewModel.readReceipts, "the toggle must show what the privacy gate is enforcing")
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(source.updateCalls.count, 1)

        // The revert fires onChange; that must not retry forever.
        viewModel.debouncedSync(settingsDataSource: source)
        try await settle()
        XCTAssertEqual(source.updateCalls.count, 1)
    }

    /// Appearance takes effect on the device immediately; the server copy is
    /// for other devices. Reverting it would push the old look next time.
    func testAFailedPushKeepsTheAppearanceChoice() async throws {
        await load()
        source.updateFails = true

        viewModel.theme = "light"
        viewModel.debouncedSync(settingsDataSource: source)
        try await settle()

        XCTAssertEqual(viewModel.theme, "light")
    }

    func testARevertReMirrorsAutoDownloadEnforcement() async throws {
        await load()
        source.updateFails = true

        viewModel.autoDownloadWifi = "none"
        viewModel.debouncedSync(settingsDataSource: source)
        try await settle()

        XCTAssertEqual(viewModel.autoDownloadWifi, "photos")
    }

    // MARK: - Sanchr Mode

    func testSanchrModeMatchingTheServerIsANoOp() async {
        await load()
        await viewModel.setSanchrMode(enabled: false, settingsDataSource: source)
        XCTAssertTrue(source.toggleCalls.isEmpty)
    }

    func testSanchrModeSuccessUpdatesTheBaseline() async throws {
        await load()

        viewModel.sanchrModeEnabled = true
        await viewModel.setSanchrMode(enabled: true, settingsDataSource: source)
        XCTAssertEqual(source.toggleCalls, [true])
        XCTAssertTrue(cache.sanchrModeEnabled)

        // An unrelated edit afterwards must carry the new mode, not the loaded one.
        viewModel.readReceipts = false
        viewModel.debouncedSync(settingsDataSource: source)
        try await settle()
        XCTAssertEqual(source.updateCalls.count, 1)
        XCTAssertTrue(source.updateCalls[0].sanchrModeEnabled)
    }

    /// The bug: a failed toggle reverted the field, the revert fired onChange,
    /// onChange called back in with the reverted value, which failed again.
    func testASanchrModeFailureRevertsWithoutLooping() async {
        await load()
        source.toggleFails = true

        viewModel.sanchrModeEnabled = true
        await viewModel.setSanchrMode(enabled: true, settingsDataSource: source)
        XCTAssertFalse(viewModel.sanchrModeEnabled)
        XCTAssertNotNil(viewModel.errorMessage)

        // What the toggle's onChange does next.
        await viewModel.setSanchrMode(enabled: false, settingsDataSource: source)
        XCTAssertEqual(source.toggleCalls, [true])
    }
}

import XCTest
@testable import Sanchr
@testable import SanchrShared

final class MessagingPrivacyGateTests: XCTestCase {

    // MARK: - readReceipt

    func test_readReceipt_defaults_allow() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.readReceipt), .allow)
    }

    func test_readReceipt_disabled_suppress() {
        let gate = makeGate(
            readReceipts: false,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.readReceipt), .suppress)
    }

    func test_readReceipt_sanchrModeOn_suppress() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: true
        )

        XCTAssertEqual(
            gate.decide(.readReceipt),
            .suppress,
            "Sanchr Mode must override readReceipts=true"
        )
    }

    // MARK: - typingIndicator

    func test_typingIndicator_defaults_allow() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.typingIndicator), .allow)
    }

    func test_typingIndicator_disabled_suppress() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: false,
            onlineStatusVisible: true,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.typingIndicator), .suppress)
    }

    func test_typingIndicator_sanchrModeOn_suppress() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: true
        )

        XCTAssertEqual(gate.decide(.typingIndicator), .suppress)
    }

    // MARK: - presenceHeartbeat

    func test_presenceHeartbeat_defaults_allow() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.presenceHeartbeat), .allow)
    }

    func test_presenceHeartbeat_onlineStatusOff_suppress() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: false,
            sanchrMode: false
        )

        XCTAssertEqual(gate.decide(.presenceHeartbeat), .suppress)
    }

    func test_presenceHeartbeat_sanchrModeOn_suppress() {
        let gate = makeGate(
            readReceipts: true,
            typingIndicator: true,
            onlineStatusVisible: true,
            sanchrMode: true
        )

        XCTAssertEqual(gate.decide(.presenceHeartbeat), .suppress)
    }

    // MARK: - Helper

    private func makeGate(
        readReceipts: Bool,
        typingIndicator: Bool,
        onlineStatusVisible: Bool,
        sanchrMode: Bool
    ) -> MessagingPrivacyGate {
        let cache = PrivacySettingsCache()
        var settings = Vync_Settings_UserSettings()
        settings.readReceipts = readReceipts
        settings.typingIndicator = typingIndicator
        settings.onlineStatusVisible = onlineStatusVisible
        settings.vyncModeEnabled = sanchrMode
        settings.profilePhotoVisibility = "everyone"
        cache.update(from: settings)
        return MessagingPrivacyGate(privacySettings: cache)
    }
}

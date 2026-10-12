import SanchrShared
import XCTest

@testable import Sanchr

/// A one-to-one message shows as delivered, and a read one shows in green.
///
/// The server reports delivery only for messages it can attribute to a
/// sender, and a sealed message hides its sender. Nobody else was telling the
/// sender either, so a message went from one tick straight to read.
final class DeliveredReceiptTests: XCTestCase {

    private func gate(readReceipts: Bool, sanchrMode: Bool) -> MessagingPrivacyGate {
        let cache = PrivacySettingsCache()
        var settings = Sanchr_Settings_UserSettings()
        settings.readReceipts = readReceipts
        settings.typingIndicator = true
        settings.onlineStatusVisible = true
        settings.sanchrModeEnabled = sanchrMode
        settings.profilePhotoVisibility = "everyone"
        cache.update(from: settings)
        return MessagingPrivacyGate(privacySettings: cache)
    }

    /// The switch is about whether you have looked. This says only that the
    /// phone has the message.
    func testADeliveredReceiptIsSentEvenWithReadReceiptsOff() {
        let gate = gate(readReceipts: false, sanchrMode: false)

        XCTAssertEqual(gate.decide(.deliveryReceipt), .allow)
        XCTAssertEqual(gate.decide(.readReceipt), .suppress)
    }

    /// Sanchr Mode holds back everything that shows the phone to be reachable.
    func testNoDeliveredReceiptIsSentInSanchrMode() {
        XCTAssertEqual(gate(readReceipts: true, sanchrMode: true).decide(.deliveryReceipt), .suppress)
    }

    func testTheWireWordsAreTheOnesTheOtherAppReads() {
        XCTAssertEqual(Message.DeliveryStatus.delivered.rawValue, "delivered")
        XCTAssertEqual(Message.DeliveryStatus.read.rawValue, "read")
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(path),
            encoding: .utf8
        )
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    }

    /// Only once the message is saved, and only for someone else's.
    func testAnArrivingMessageIsReportedAfterItIsSaved() throws {
        let repository = try source("Shared/Repositories/MessageRepository.swift")
        let save = try XCTUnwrap(
            repository.range(of: "localDatabase.saveReceivedMessage(message, queueAck: !isOutgoing)"))
        let report = try XCTUnwrap(repository.range(of: "sendDeliveredReceipt(\n                    conversationId: innerPayload.conversationId"))
        XCTAssertLessThan(save.lowerBound, report.lowerBound)

        let guarded = repository[..<report.lowerBound].suffix(60)
        XCTAssertTrue(guarded.contains("if !isOutgoing {"), "not for our own message echoed from another device")
    }

    func testItIsGatedSentAsDeliveredAndOnlyForOneToOneChats() throws {
        let repository = try source("Shared/Repositories/MessageRepository.swift")
        let start = try XCTUnwrap(repository.range(of: "private func sendDeliveredReceipt("))
        let rest = repository[start.upperBound...]
        let body = rest[..<(rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex)]

        XCTAssertTrue(body.contains("privacyGate.decide(.deliveryReceipt) == .allow"))
        XCTAssertTrue(body.contains("conversation.type == .oneToOne"))
        XCTAssertTrue(body.contains("status: .delivered"))
        XCTAssertTrue(body.contains("receiptDelayNanoseconds()"), "the same short random wait a read receipt gets")
    }

    func testAReadReceiptStillSaysRead() throws {
        let repository = try source("Shared/Repositories/MessageRepository.swift")
        XCTAssertTrue(repository.contains("status: Message.DeliveryStatus = .read"))
        XCTAssertTrue(repository.contains("receiptUpdate.status = status.rawValue"))
    }

    /// One tick sent, two delivered, two green read — in the chat and in the list.
    func testOnlyTheReadTickIsGreen() throws {
        for path in [
            "Features/Chats/Presentation/MessageBubble.swift",
            "Features/Chats/Presentation/ConversationRow.swift",
        ] {
            let text = try source(path)
            XCTAssertTrue(text.contains("SanchrColors.success"), path)
            XCTAssertFalse(text.contains("? SanchrColors.accent"), path)
        }
    }
}

import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// Delivery acks are queued durably and sent in one batch per burst, not
/// one RPC per envelope plus a flush.
final class AckBatchingTests: XCTestCase {

    func testAQueuedAckIsDurableAndDeduplicated() async throws {
        let database = try LocalDatabase(
            path: FileManager.default.temporaryDirectory.appendingPathComponent("acks-\(UUID().uuidString).sqlite"),
            passphraseProvider: { "unit-test-passphrase" }
        )
        let ack = PendingMessageAck(conversationId: "c1", messageId: "m1", createdAt: Date())
        try await database.enqueuePendingMessageAck(ack)
        try await database.enqueuePendingMessageAck(ack)

        let pending = try await database.fetchPendingMessageAcks(limit: 10)
        XCTAssertEqual(pending.map(\.messageId), ["m1"])
    }

    func testTheRealtimePathQueuesInsteadOfCallingTheServerPerEnvelope() throws {
        let repository = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Shared/Repositories/MessageRepository.swift"),
            encoding: .utf8
        )
        let ack = try XCTUnwrap(repository.range(of: "private func ackDeliveredEnvelope(messageId: String, conversationId: String) async -> Bool {"))
        let body = String(repository[ack.upperBound...].prefix(800))
        XCTAssertTrue(body.contains("localDatabase.enqueuePendingMessageAck(ack)"))
        XCTAssertTrue(body.contains("scheduleAckFlush()"))
        XCTAssertFalse(body.contains("grpcClient.messagingService.ackMessages"))
        XCTAssertFalse(repository.contains("let flushedCount = (try? await self.flushPendingAcks()) ?? 0"),
                       "no per-envelope flush in the stream handlers")
    }
}

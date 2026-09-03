import XCTest
@testable import SanchrShared

/// Unit tests for `ShareSendDispatcher`, the SanchrShared-side coordinator
/// that the share extension's `ShareSendCoordinator` delegates to.
///
/// These tests deliberately exercise the dispatcher rather than the
/// extension-side `ShareSendCoordinator` actor: the share-extension target is
/// an `app-extension` binary that cannot be loaded into a unit-test host, so
/// we keep the test seam (the `ShareMessageSending` protocol) inside
/// SanchrShared and verify the multi-recipient fan-out logic here.
final class MultiRecipientSendTests: XCTestCase {

    // MARK: - (a) all recipients succeed

    func test_allRecipientsSucceed_emitsSuccessForEach_andOverallProgressReachesOne() async {
        let sender = FakeShareMessageSender()
        let dispatcher = ShareSendDispatcher(sender: sender)
        let observer = OutcomeObserver()

        await dispatcher.send(
            units: [.text("hello")],
            to: ["r1", "r2", "r3"]
        ) { id, outcome, overall in
            Task { await observer.append(id: id, outcome: outcome, overall: overall) }
        }

        await observer.drain()
        let final = await observer.terminalByRecipient()

        XCTAssertEqual(final["r1"], .success)
        XCTAssertEqual(final["r2"], .success)
        XCTAssertEqual(final["r3"], .success)

        let maxOverall = await observer.maxOverall()
        XCTAssertEqual(maxOverall, 1.0, accuracy: 0.0001)

        let calls = await sender.recordedCalls()
        XCTAssertEqual(Set(calls.map(\.chatId)), ["r1", "r2", "r3"])
        XCTAssertTrue(calls.allSatisfy { $0.kind == .text("hello") })
    }

    // MARK: - (b) one recipient fails, others continue

    func test_oneRecipientFails_othersStillSucceed() async {
        let sender = FakeShareMessageSender()
        await sender.failTextOn(["r2"])
        let dispatcher = ShareSendDispatcher(sender: sender)
        let observer = OutcomeObserver()

        await dispatcher.send(
            units: [.text("hi")],
            to: ["r1", "r2", "r3"]
        ) { id, outcome, overall in
            Task { await observer.append(id: id, outcome: outcome, overall: overall) }
        }

        await observer.drain()
        let final = await observer.terminalByRecipient()

        XCTAssertEqual(final["r1"], .success)
        XCTAssertEqual(final["r3"], .success)
        guard case .failure = final["r2"] else {
            XCTFail("Expected r2 to fail, got \(String(describing: final["r2"]))")
            return
        }

        let maxOverall = await observer.maxOverall()
        XCTAssertEqual(maxOverall, 1.0, accuracy: 0.0001)
    }

    // MARK: - (c) multi-unit payload fans out correctly

    func test_multiUnitPayload_fansOutAllUnitsToEveryRecipientInOrder() async {
        let sender = FakeShareMessageSender()
        let dispatcher = ShareSendDispatcher(sender: sender)

        let media = Message.MediaAttachment(
            url: URL(fileURLWithPath: "/tmp/x.jpg"),
            encryptionKey: Data(),
            encryptionIV: Data(),
            mimeType: "image/jpeg",
            sizeBytes: 1234,
            caption: "look",
            filename: "x.jpg"
        )

        await dispatcher.send(
            units: [.text("first"), .media(media), .text("third")],
            to: ["r1", "r2"]
        ) { _, _, _ in }

        let calls = await sender.recordedCalls()

        // Per-recipient: every unit is delivered, in order.
        let r1Calls = calls.filter { $0.chatId == "r1" }.map(\.kind)
        let r2Calls = calls.filter { $0.chatId == "r2" }.map(\.kind)
        XCTAssertEqual(r1Calls, [.text("first"), .media("x.jpg"), .text("third")])
        XCTAssertEqual(r2Calls, [.text("first"), .media("x.jpg"), .text("third")])
    }

    // MARK: - (d) cancellation honored

    func test_cancellation_haltsBeforeDispatchingFurtherUnits() async {
        let sender = FakeShareMessageSender()
        await sender.setSendDelayNanos(50_000_000) // 50ms — slow enough to interleave a cancel
        let dispatcher = ShareSendDispatcher(sender: sender)
        let observer = OutcomeObserver()

        let task = Task {
            await dispatcher.send(
                units: [.text("a"), .text("b"), .text("c")],
                to: ["r1", "r2", "r3", "r4"]
            ) { id, outcome, overall in
                Task { await observer.append(id: id, outcome: outcome, overall: overall) }
            }
        }

        // Give the task a moment to start, then cancel.
        try? await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()
        await task.value

        await observer.drain()

        // Cancellation must surface as `.cancelled` for at least one
        // recipient, AND the dispatcher must not have delivered every unit
        // to every recipient (otherwise cancellation was ignored).
        let outcomes = await observer.allTerminalOutcomes()
        XCTAssertTrue(
            outcomes.contains(.cancelled),
            "Expected at least one recipient to surface .cancelled, got: \(outcomes)"
        )

        let calls = await sender.recordedCalls()
        let totalUnitsIfNotCancelled = 3 * 4
        XCTAssertLessThan(
            calls.count,
            totalUnitsIfNotCancelled,
            "Cancellation should have prevented at least one send call (got \(calls.count) of \(totalUnitsIfNotCancelled))"
        )
    }
}

// MARK: - Test doubles

/// Lightweight, isolation-correct fake `ShareMessageSending` for the tests.
/// Records every call (chat id + a coarse "kind" tag for assertions) and
/// optionally fails a configurable subset of recipients on `sendText`.
private actor FakeShareMessageSender: ShareMessageSending {

    enum CallKind: Equatable {
        case text(String)
        case media(String) // filename
    }

    struct Call: Equatable {
        let chatId: String
        let kind: CallKind
    }

    private var calls: [Call] = []
    private var failTextRecipients: Set<String> = []
    private var sendDelayNanos: UInt64 = 0

    func failTextOn(_ recipients: Set<String>) { self.failTextRecipients = recipients }
    func setSendDelayNanos(_ nanos: UInt64) { self.sendDelayNanos = nanos }
    func recordedCalls() -> [Call] { calls }

    nonisolated func sendText(
        _ text: String,
        to chatId: String
    ) async throws -> MessageSendReceipt {
        try await self.recordSendText(text, to: chatId)
    }

    nonisolated func sendMedia(
        attachment: Message.MediaAttachment,
        caption: String?,
        to chatId: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> MessageSendReceipt {
        try await self.recordSendMedia(filename: attachment.filename ?? "", to: chatId)
    }

    private func recordSendText(_ text: String, to chatId: String) async throws -> MessageSendReceipt {
        let delay = sendDelayNanos
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if Task.isCancelled { throw CancellationError() }
        calls.append(Call(chatId: chatId, kind: .text(text)))
        if failTextRecipients.contains(chatId) {
            throw NSError(domain: "FakeSender", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        return MessageSendReceipt(
            chatId: chatId,
            messageId: "\(chatId)-msg",
            serverTimestampMs: 1
        )
    }

    private func recordSendMedia(filename: String, to chatId: String) async throws -> MessageSendReceipt {
        let delay = sendDelayNanos
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if Task.isCancelled { throw CancellationError() }
        calls.append(Call(chatId: chatId, kind: .media(filename)))
        return MessageSendReceipt(
            chatId: chatId,
            messageId: "\(chatId)-media",
            serverTimestampMs: 1
        )
    }
}

/// Captures every progress callback the dispatcher emits, in order. Lives
/// inside an actor so the `@Sendable` closure can append safely from any
/// task.
private actor OutcomeObserver {
    struct Event { let id: String; let outcome: ShareRecipientOutcome; let overall: Double }
    private var events: [Event] = []

    func append(id: String, outcome: ShareRecipientOutcome, overall: Double) {
        events.append(Event(id: id, outcome: outcome, overall: overall))
    }

    /// Allow any in-flight `Task { await observer.append(...) }` calls to
    /// settle before reading the buffer. The dispatcher's progress closure
    /// is `@Sendable` and we hop into a Task inside it, so synchronous
    /// `await` on the dispatcher's `send(...)` is not enough — we have to
    /// flush the actor's mailbox.
    func drain() async {
        // Eight bare yields were "enough in practice" until the machine ran a
        // full suite at a load average near 200, when the fire-and-forget
        // append tasks had not landed and every outcome read as nil. Wait
        // for the mailbox to go quiet instead: the count unchanged across
        // three polls, bounded so a genuinely missing event still fails fast.
        var lastCount = -1
        var stablePolls = 0
        for _ in 0..<200 {
            await Task.yield()
            if events.count == lastCount, !events.isEmpty {
                stablePolls += 1
                if stablePolls >= 3 { return }
            } else {
                stablePolls = 0
                lastCount = events.count
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    func terminalByRecipient() -> [String: ShareRecipientOutcome] {
        var byId: [String: ShareRecipientOutcome] = [:]
        for event in events {
            // Skip the transient `.sending` so the final state wins.
            if case .sending = event.outcome { continue }
            byId[event.id] = event.outcome
        }
        return byId
    }

    func allTerminalOutcomes() -> Set<ShareRecipientOutcome> {
        Set(terminalByRecipient().values)
    }

    func maxOverall() -> Double {
        events.map(\.overall).max() ?? 0
    }
}

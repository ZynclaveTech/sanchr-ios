import Foundation

// MARK: - ShareMessageSending

/// Narrow test seam around `MessageSender` that `ShareSendDispatcher` depends
/// on. Keeping the dispatcher dependency-inverted behind this protocol lets
/// the unit-test target substitute a fake sender without having to link the
/// share-extension target (which, as an app-extension binary, cannot be
/// loaded into a test host) and without pulling the full Signal / gRPC /
/// media-upload stack into the tests.
///
/// Only the two send entry points that the share extension actually calls
/// live on this protocol. If the extension ever needs richer behaviour
/// (cancellation, reactions, edits) add them here, not directly on
/// `MessageSender`, so the test seam stays minimal and intentional.
public protocol ShareMessageSending: Sendable {
    func sendText(
        _ text: String,
        to chatId: String
    ) async throws -> MessageSendReceipt

    func sendMedia(
        attachment: Message.MediaAttachment,
        caption: String?,
        to chatId: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> MessageSendReceipt
}

extension MessageSender: ShareMessageSending {}

// MARK: - ShareSendUnit

/// A single, fully-resolved "thing to send" that the dispatcher hands to the
/// sender, one after another, for each recipient. Callers (the share
/// extension's `ShareSendCoordinator`) are responsible for flattening a
/// possibly-compound `SharePayload` into an ordered list of these units.
///
/// The caption lives INSIDE the media attachment for media units and inside
/// the body for text units, so the dispatcher itself never has to worry
/// about where the caption goes.
public enum ShareSendUnit: Sendable {
    case text(String)
    case media(Message.MediaAttachment)
}

// MARK: - ShareRecipientOutcome

/// Terminal-or-transitional state reported by the dispatcher for a single
/// recipient. The share-extension UI maps this into its own view-layer
/// enum; keeping them separate lets the UI evolve (adding pending states,
/// retry affordances, etc.) without touching SanchrShared.
public enum ShareRecipientOutcome: Sendable, Equatable, Hashable {
    case sending
    case success
    case failure(String)
    case cancelled
}

// MARK: - ShareSendDispatcher

/// Drives a multi-recipient share send.
///
/// Responsibilities:
///   1. Fan every recipient out in parallel so one slow/failing recipient
///      doesn't block the others.
///   2. Preserve per-recipient ordering across the units of a compound
///      payload (all of recipient A's units run in order; but A, B, C run
///      concurrently).
///   3. Report progress through a closure so the UI (SwiftUI sheet) can
///      bind to it without knowing the dispatcher exists.
///   4. Honour `Task.isCancelled` so dismissing the share sheet mid-send
///      stops further work cleanly.
///
/// The dispatcher has no UI, no dependency stack, and no singletons — it is
/// a pure coordinator over whatever `ShareMessageSending` implementation the
/// caller injects. That makes it fully unit-testable from the main-app test
/// target, which cannot `@testable import` the share extension.
public actor ShareSendDispatcher {

    private let sender: ShareMessageSending

    public init(sender: ShareMessageSending) {
        self.sender = sender
    }

    /// Fan out `units` to every recipient in `recipients` concurrently.
    ///
    /// - Parameters:
    ///   - units: Ordered send units. Each recipient receives every unit in
    ///            the given order. An empty `units` array is a no-op that
    ///            immediately reports `.success` for every recipient.
    ///   - recipientIds: Stable identifiers for the recipients. The
    ///            dispatcher doesn't care whether these are 1:1 chat ids or
    ///            group ids — it forwards them verbatim to the sender.
    ///   - progress: Invoked once per state transition per recipient, plus
    ///            a final overall-progress fraction in `[0, 1]`. Callers
    ///            MUST tolerate being called from arbitrary tasks and
    ///            MUST hop to the main actor themselves if they mutate UI
    ///            state inside the closure.
    public func send(
        units: [ShareSendUnit],
        to recipientIds: [String],
        progress: @Sendable @escaping (String, ShareRecipientOutcome, Double) -> Void
    ) async {
        guard !recipientIds.isEmpty else { return }

        let total = recipientIds.count
        let counter = CompletedCount()

        await withTaskGroup(of: Void.self) { group in
            for recipientId in recipientIds {
                group.addTask { [sender] in
                    if Task.isCancelled {
                        progress(recipientId, .cancelled, 0)
                        let done = await counter.increment()
                        progress(recipientId, .cancelled, Double(done) / Double(total))
                        return
                    }

                    progress(recipientId, .sending, 0)

                    let outcome: ShareRecipientOutcome
                    do {
                        try await Self.dispatch(
                            units: units,
                            to: recipientId,
                            sender: sender
                        )
                        outcome = .success
                    } catch is CancellationError {
                        outcome = .cancelled
                    } catch {
                        outcome = .failure(Self.friendlyError(error))
                    }

                    let done = await counter.increment()
                    progress(recipientId, outcome, Double(done) / Double(total))
                }
            }
            await group.waitForAll()
        }
    }

    // MARK: - Helpers

    private static func dispatch(
        units: [ShareSendUnit],
        to recipientId: String,
        sender: ShareMessageSending
    ) async throws {
        for unit in units {
            if Task.isCancelled { throw CancellationError() }
            switch unit {
            case .text(let body):
                _ = try await sender.sendText(body, to: recipientId)
            case .media(let attachment):
                _ = try await sender.sendMedia(
                    attachment: attachment,
                    caption: attachment.caption,
                    to: recipientId,
                    progress: { _ in }
                )
            }
        }
    }

    private static func friendlyError(_ error: Error) -> String {
        if let appError = error as? AppError {
            return appError.localizedDescription
        }
        return error.localizedDescription
    }
}

/// Thread-safe completion counter used by the structured task group to
/// drive the overall-progress fraction. An actor keeps the increments
/// race-free without leaking isolation into the `@Sendable` progress
/// closure passed in by the caller.
private actor CompletedCount {
    private var value: Int = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

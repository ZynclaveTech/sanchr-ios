import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// A 10,000-message demo room with every content type, used to measure the
/// work the transcript repeats on each message change rather than reason about
/// it. `rebuildSections` runs on every new message, status flip and reaction,
/// so its cost is paid constantly and scales with everything loaded.
@MainActor
final class ChatTranscriptScaleTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private static let messageCount = 10_000

    // MARK: - Demo room

    private func attachment(_ id: String, mime: String) -> Message.MediaAttachment {
        var a = Message.MediaAttachment(
            url: URL(string: "sanchr-media://\(id)")!,
            encryptionKey: Data(count: 32),
            encryptionIV: Data(count: 12),
            mimeType: mime,
            sizeBytes: 128_000,
            thumbnailURL: nil
        )
        a.width = 1600
        a.height = 1200
        a.blurHash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        return a
    }

    /// Cycles through every content type the transcript can render, including
    /// multi-attachment albums and voice notes carrying a waveform — the
    /// heaviest payloads a message can hold.
    private func content(for index: Int) -> Message.MessageContent {
        switch index % 8 {
        case 0:
            return .text("Message \(index) — a fairly ordinary line of chat text.")
        case 1:
            return .image(.init(attachment("img\(index)", mime: "image/jpeg")))
        case 2:
            return .image(.init((0..<4).map { attachment("album\(index)-\($0)", mime: "image/jpeg") }))
        case 3:
            return .video(.init(attachment("vid\(index)", mime: "video/mp4")))
        case 4:
            var voice = attachment("voice\(index)", mime: "audio/mp4")
            voice.isVoiceMessage = true
            voice.audioDurationMs = 4200
            voice.audioWaveform = (0..<64).map { Float($0 % 10) / 10 }
            return .audio(.init(voice))
        case 5:
            var doc = attachment("doc\(index)", mime: "application/pdf")
            doc.filename = "report-\(index).pdf"
            return .document(.init(doc))
        case 6:
            return .location(latitude: 12.97 + Double(index % 10) / 1000, longitude: 77.59)
        default:
            return .contact(name: "Contact \(index)", phoneNumber: "+1555000\(index % 1000)")
        }
    }

    private lazy var demoRoom: [Message] = {
        let start = calendar.date(byAdding: .day, value: -120, to: Date())!
        return (0..<Self.messageCount).map { index in
            // ~83 messages a day across 120 days, so the transcript has a
            // realistic number of day sections rather than one enormous block.
            let day = calendar.date(byAdding: .day, value: index / 83, to: start)!
            let timestamp = calendar.startOfDay(for: day)
                .addingTimeInterval(TimeInterval((index % 83) * 900))
            return Message(
                id: "m\(index)",
                conversationId: "demo-room",
                senderId: index % 3 == 0 ? "me" : "peer",
                timestamp: timestamp,
                content: content(for: index),
                status: .sent,
                isOutgoing: index % 3 == 0
            )
        }
    }()

    /// The grouping this replaced: dictionary, per-day sort, then sort days.
    private func referenceSections(_ messages: [Message]) -> [MessageSection] {
        Dictionary(grouping: messages) { calendar.startOfDay(for: $0.timestamp) }
            .map { day, msgs in
                MessageSection(
                    id: day,
                    title: ChatDetailViewModel.sectionTitle(for: day, calendar: calendar),
                    messages: msgs.sorted { $0.timestamp < $1.timestamp }
                )
            }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Correctness at scale

    func testDemoRoomIsBuiltAsExpected() {
        XCTAssertEqual(demoRoom.count, Self.messageCount)
        let sections = ChatDetailViewModel.buildSections(from: demoRoom, calendar: calendar)
        XCTAssertEqual(
            sections.reduce(0) { $0 + $1.messages.count }, Self.messageCount,
            "no message may be dropped at scale"
        )
        XCTAssertGreaterThan(sections.count, 100, "the demo room should span many days")
    }

    func testMatchesTheReferenceGroupingAtTenThousand() {
        let fast = ChatDetailViewModel.buildSections(from: demoRoom, calendar: calendar)
        let reference = referenceSections(demoRoom)
        XCTAssertEqual(fast.map(\.id), reference.map(\.id))
        XCTAssertEqual(
            fast.map { $0.messages.map(\.id) },
            reference.map { $0.messages.map(\.id) }
        )
    }

    // MARK: - Cost

    /// Reported so the two are comparable on the same machine and transcript.
    func testSectionBuildingCostAtTenThousand() {
        func time(_ label: String, _ body: () -> Void) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<5 { body() }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) / 5
            print(String(format: "  %@: %.2f ms per rebuild", label, elapsed * 1000))
            return elapsed
        }

        let new = time("single pass    ") {
            _ = ChatDetailViewModel.buildSections(from: demoRoom, calendar: calendar)
        }
        let old = time("dictionary+sort") {
            _ = self.referenceSections(self.demoRoom)
        }
        print(String(format: "  improvement: %.1fx", old / max(new, .leastNonzeroMagnitude)))

        XCTAssertLessThan(
            new, old,
            "the single pass must not be slower than the grouping it replaced"
        )
    }

    func testSectionBuildingStaysWithinAFrameAtTenThousand() {
        let start = CFAbsoluteTimeGetCurrent()
        _ = ChatDetailViewModel.buildSections(from: demoRoom, calendar: calendar)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // This runs on the main thread for every message change. A 120 ms
        // ceiling is loose on purpose — CI machines are noisy — but it fails
        // if the cost regresses by an order of magnitude.
        XCTAssertLessThan(
            elapsed, 0.120,
            String(format: "rebuild took %.0f ms at %d messages", elapsed * 1000, Self.messageCount)
        )
    }

    /// What the window is actually for: the rebuild that runs on every message
    /// change should cost the window, not the scroll history.
    func testTrimmedWindowRebuildsFarFasterThanTheFullTranscript() {
        let windowed = Array(demoRoom.suffix(ChatDetailViewModel.retainedWindowSize))

        func time(_ messages: [Message]) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<5 { _ = ChatDetailViewModel.buildSections(from: messages, calendar: calendar) }
            return (CFAbsoluteTimeGetCurrent() - start) / 5
        }

        let full = time(demoRoom)
        let trimmed = time(windowed)
        print(String(format: "  full transcript (%d): %.2f ms", demoRoom.count, full * 1000))
        print(String(format: "  trimmed window  (%d): %.2f ms", windowed.count, trimmed * 1000))
        print(String(format: "  reduction: %.0fx", full / max(trimmed, .leastNonzeroMagnitude)))

        XCTAssertLessThan(trimmed, full / 5, "the window must be dramatically cheaper")
    }

    func measureSectionBuilding() {
        measure { _ = ChatDetailViewModel.buildSections(from: demoRoom, calendar: calendar) }
    }
}

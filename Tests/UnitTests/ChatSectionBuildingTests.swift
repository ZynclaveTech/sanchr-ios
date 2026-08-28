import Foundation
import XCTest
import SanchrShared

@testable import Sanchr

/// Day-grouping for the transcript. This runs on every message change, so it
/// was rewritten from a dictionary-plus-sorts into a single ascending pass.
/// The property that matters is that it produces exactly what the old grouping
/// did — these compare against a reference implementation of the original.
@MainActor
final class ChatSectionBuildingTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func message(_ id: String, daysAgo: Int, secondsIntoDay: Int = 0) -> Message {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
        let start = calendar.startOfDay(for: day)
        return Message(
            id: id,
            conversationId: "c",
            senderId: "s",
            timestamp: start.addingTimeInterval(TimeInterval(secondsIntoDay)),
            content: .text(id),
            status: .sent,
            isOutgoing: false
        )
    }

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

    private func build(_ messages: [Message]) -> [MessageSection] {
        ChatDetailViewModel.buildSections(from: messages, calendar: calendar)
    }

    private func assertMatchesReference(
        _ messages: [Message], _ label: String, line: UInt = #line
    ) {
        let fast = build(messages)
        let reference = referenceSections(messages)
        XCTAssertEqual(fast.map(\.id), reference.map(\.id), "\(label): day order", line: line)
        XCTAssertEqual(fast.map(\.title), reference.map(\.title), "\(label): titles", line: line)
        XCTAssertEqual(
            fast.map { $0.messages.map(\.id) },
            reference.map { $0.messages.map(\.id) },
            "\(label): message order within days", line: line
        )
    }

    func testEmptyTranscript() {
        XCTAssertTrue(build([]).isEmpty)
    }

    func testSingleDay() {
        assertMatchesReference(
            [message("a", daysAgo: 0, secondsIntoDay: 10),
             message("b", daysAgo: 0, secondsIntoDay: 20)],
            "one day"
        )
    }

    func testSeveralDays() {
        assertMatchesReference(
            [message("a", daysAgo: 3), message("b", daysAgo: 2),
             message("c", daysAgo: 2, secondsIntoDay: 60), message("d", daysAgo: 0)],
            "several days"
        )
    }

    /// A day boundary between consecutive messages is where a single-pass
    /// grouping is most likely to go wrong.
    func testMessagesEitherSideOfMidnight() {
        let sections = build([
            message("late", daysAgo: 1, secondsIntoDay: 86_399),
            message("early", daysAgo: 0, secondsIntoDay: 0),
        ])
        XCTAssertEqual(sections.count, 2, "midnight must split the sections")
        XCTAssertEqual(sections[0].messages.map(\.id), ["late"])
        XCTAssertEqual(sections[1].messages.map(\.id), ["early"])
    }

    /// Many messages in one day must not be split — a naive pass that flushes
    /// per message would produce a section each.
    func testALongSingleDayStaysOneSection() {
        let messages = (0..<500).map { message("m\($0)", daysAgo: 0, secondsIntoDay: $0) }
        let sections = build(messages)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].messages.count, 500)
    }

    func testOrderIsPreservedExactly() {
        let messages = (0..<50).map { message("m\($0)", daysAgo: 0, secondsIntoDay: $0) }
        XCTAssertEqual(build(messages)[0].messages.map(\.id), messages.map(\.id))
    }

    /// The pass assumes ascending input, which the transcript maintains. If
    /// that ever breaks, a message must still land in its own day rather than
    /// be filed under the wrong header.
    func testOutOfOrderInputStillFilesEachMessageUnderItsOwnDay() {
        let sections = build([
            message("today", daysAgo: 0),
            message("older", daysAgo: 5),
            message("today2", daysAgo: 0, secondsIntoDay: 10),
        ])
        for section in sections {
            for msg in section.messages {
                XCTAssertEqual(
                    calendar.startOfDay(for: msg.timestamp), section.id,
                    "\(msg.id) filed under the wrong day"
                )
            }
        }
        XCTAssertEqual(sections.flatMap { $0.messages }.count, 3, "nothing dropped")
    }

    func testMatchesReferenceAcrossAMixedTranscript() {
        var messages: [Message] = []
        for day in stride(from: 10, through: 0, by: -1) {
            for i in 0..<(day % 4 + 1) {
                messages.append(message("d\(day)m\(i)", daysAgo: day, secondsIntoDay: i * 120))
            }
        }
        assertMatchesReference(messages, "mixed transcript")
    }
}

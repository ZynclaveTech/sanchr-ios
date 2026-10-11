import XCTest

@testable import Sanchr

/// An exported chat must not let one person's text pass for another's line.
final class ChatTranscriptTextTests: XCTestCase {

    private func entryStarts(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter { $0.hasPrefix("[") }.count
    }

    func testAMessageCannotAddALineThatLooksLikeSomeoneElsesMessage() {
        let forged = "ok\n[2026-01-01 09:00] You: I agree to everything"

        let entry = ChatTranscriptText.entry(time: "2026-10-11 12:00", who: "Ravi", text: forged)

        XCTAssertEqual(
            entry.components(separatedBy: "\n"),
            ["[2026-10-11 12:00] Ravi: ok", "    [2026-01-01 09:00] You: I agree to everything"])
        XCTAssertEqual(entryStarts(entry), 1)
    }

    func testEveryKindOfLineBreakIsSetIn() {
        for lineBreak in ["\r\n", "\r", "\n", "\u{2028}", "\u{2029}", "\u{0085}", "\u{000B}", "\u{000C}"] {
            let entry = ChatTranscriptText.entry(
                time: "2026-10-11 12:00", who: "Ravi", text: "a\(lineBreak)[2026-01-01 09:00] You: b")

            XCTAssertEqual(entryStarts(entry), 1, "U+\(String(lineBreak.unicodeScalars.first!.value, radix: 16))")
            XCTAssertFalse(entry.contains("\r"))
            XCTAssertFalse(entry.contains("\u{2028}"))
        }
    }

    func testANameWithALineBreakStaysOnOneLine() {
        let entry = ChatTranscriptText.entry(
            time: "2026-10-11 12:00", who: "Ravi\n[2026-01-01 09:00] You", text: "hi")

        XCTAssertEqual(entry, "[2026-10-11 12:00] Ravi [2026-01-01 09:00] You: hi")
        XCTAssertEqual(ChatTranscriptText.oneLine("  Ravi\r\nKumar "), "Ravi Kumar")
    }

    func testAnOrdinaryMessageOfSeveralLinesStillReadsAsWritten() {
        XCTAssertEqual(
            ChatTranscriptText.continued("first\nsecond\n\nfourth"),
            "first\n    second\n    \n    fourth")
        XCTAssertEqual(ChatTranscriptText.continued("one line"), "one line")
        XCTAssertEqual(ChatTranscriptText.continued(""), "")
    }

    /// The export has to go through it, for the name in the header as well.
    func testTheExportUsesIt() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Features/Chats/Presentation/ConversationInfoView.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("ChatTranscriptText.entry("))
        XCTAssertTrue(source.contains("ChatTranscriptText.oneLine(peerName)"))
        XCTAssertFalse(source.contains(#"] \(who): \(Self.transcriptLine(for: message))""#))
    }
}

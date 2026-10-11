import Foundation

/// How a chat's text is laid out when it is exported, so that what one
/// person typed cannot pass for a line written by someone else.
///
/// An exported entry starts at the margin with a bracketed time. A message is
/// whatever its sender typed, line breaks included — so "ok", then a line
/// reading "[2026-01-01 09:00] You: I agree to everything", used to come out
/// as a separate entry in the other person's name. A name can carry a line
/// break too.
enum ChatTranscriptText {
    /// Every kind of line break, not only the one a keyboard types.
    private static let lineBreaks: Set<Character> = [
        "\r\n", "\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}",
    ]

    static let continuationIndent = "    "

    /// A message's text with every line after its first set in from the
    /// margin, where it cannot be mistaken for the start of an entry.
    static func continued(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: lineBreaks.contains)
            .joined(separator: "\n" + continuationIndent)
    }

    /// A name held to one line.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: lineBreaks.contains)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// One entry: `[time] who: text`.
    static func entry(time: String, who: String, text: String) -> String {
        "[\(time)] \(oneLine(who)): \(continued(text))"
    }
}

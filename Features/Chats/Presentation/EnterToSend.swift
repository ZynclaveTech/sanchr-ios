import Foundation

/// Decides whether a change to the composer's text was the Return key being
/// pressed to send.
///
/// "Enter sends message" is a user setting, on by default, and it hung off
/// `.onSubmit`. A `TextField(axis: .vertical)` is multiline: the Return key
/// inserts a line break and does not submit, so `onSubmit` never fired and the
/// setting did nothing in either position.
///
/// The newline the field inserts is itself the signal. Watching for it is
/// reliable precisely because it is the field's own documented behaviour,
/// rather than an event that may or may not be delivered.
enum EnterToSend {

    /// The message to send, or nil if this edit was not a send.
    ///
    /// Deliberately strict. It fires only when exactly one newline has been
    /// appended to the end of the previous text, which is what a single Return
    /// keypress at the end of a message produces — and nothing else does:
    ///
    /// - Pasting a block of text that happens to end in a newline changes more
    ///   than one character, so it types rather than sends.
    /// - Pressing Return in the middle of a message inserts a line break
    ///   somewhere other than the end, so the text keeps growing instead.
    /// - A message that is only whitespace has nothing to send.
    static func submission(previous: String, current: String, enabled: Bool) -> String? {
        guard enabled else { return nil }
        guard current == previous + "\n" else { return nil }

        let body = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}

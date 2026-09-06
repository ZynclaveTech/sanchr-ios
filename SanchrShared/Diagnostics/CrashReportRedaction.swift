import Foundation

/// What a crash report is allowed to say.
///
/// A stack trace from a messenger can carry a phone number, a message body
/// or a media path in an error's text, and none of that may reach a third
/// party. Type and call site are what makes a report useful; the free text
/// almost never is.
///
/// Mirrors Android's `CrashReportRedaction` so a report from either platform
/// withholds the same things.
public enum CrashReportRedaction {
    private static let email = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private static let phone = try! NSRegularExpression(pattern: "\\+?\\d[\\d ()-]{7,}\\d")
    private static let fileURL = try! NSRegularExpression(pattern: "file://\\S+")
    private static let longBase64 = try! NSRegularExpression(pattern: "[A-Za-z0-9+/=]{24,}")
    private static let path = try! NSRegularExpression(pattern: "(/[\\w.-]+){2,}")

    /// `text` with anything that could identify a person or a message replaced.
    ///
    /// Order matters: emails and phone numbers go first, because a path or a
    /// base64 run could otherwise swallow them and leave a partial number.
    public static func redact(_ text: String?) -> String {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        var out = text
        out = replace(out, email, with: "[email]")
        out = replace(out, phone, with: "[phone]")
        out = replace(out, fileURL, with: "[url]")
        out = replace(out, longBase64, with: "[data]")
        out = replace(out, path, with: "[path]")
        return out
    }

    /// A one-line label for an error: its type and domain, with no free text.
    ///
    /// Preferred over `redact` where a summary suffices, because withholding
    /// the message entirely cannot leak by a shape nobody anticipated.
    public static func summarise(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(type(of: error)) domain=\(nsError.domain) code=\(nsError.code)"
    }

    private static func replace(_ input: String, _ regex: NSRegularExpression, with template: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: template)
    }
}

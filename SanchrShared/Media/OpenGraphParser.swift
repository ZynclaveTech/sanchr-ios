import Foundation

/// What a page says about itself, from its Open Graph / Twitter tags with
/// `<title>` as the fallback.
public struct ParsedPage: Equatable, Sendable {
    public let title: String?
    public let imageURL: URL?
}

/// A small, dependency-free reader of the few `<meta>` tags a preview card
/// needs. The same rules as Android's `OpenGraphParser`, so a link shows the
/// same card on both.
public enum OpenGraphParser {
    private static let maxTitle = 300

    private static let meta = regex(#"<meta\b[^>]*>"#)
    private static let attribute = regex(#"\b(property|name|content)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let title = regex(#"<title[^>]*>(.*?)</title>"#)
    private static let entity = regex(#"&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos|nbsp);"#)
    private static let whitespace = regex(#"\s+"#)

    public static func parse(html: String, pageURL: URL) -> ParsedPage {
        var tags: [String: String] = [:]
        for tag in matches(meta, in: html) {
            var key: String?
            var content: String?
            for attr in matches(attribute, in: tag[0]) {
                let value = [attr[2], attr[3], attr[4]].first { !$0.isEmpty } ?? ""
                switch attr[1].lowercased() {
                case "property", "name": key = value.lowercased()
                case "content": content = value
                default: break
                }
            }
            if let key, let content, tags[key] == nil { tags[key] = content }
        }

        let rawTitle = tags["og:title"] ?? tags["twitter:title"] ?? matches(title, in: html).first?[1]
        let cleanTitle = rawTitle
            .map(decode)
            .map { replace(whitespace, in: $0, with: " ").trimmingCharacters(in: .whitespaces) }
            .map { String($0.prefix(maxTitle)) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let image = (tags["og:image"] ?? tags["og:image:url"] ?? tags["twitter:image"])
            .flatMap { resolve(decode($0).trimmingCharacters(in: .whitespaces), against: pageURL) }
        return ParsedPage(title: cleanTitle, imageURL: image)
    }

    /// Resolves a possibly relative image reference against the page, dropping
    /// anything that is not http(s) — `data:`, `javascript:` and `file:` are
    /// not things to fetch.
    static func resolve(_ reference: String, against pageURL: URL) -> URL? {
        guard !reference.isEmpty,
              let url = URL(string: reference, relativeTo: pageURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    public static func decode(_ string: String) -> String {
        var result = ""
        var cursor = string.startIndex
        let ns = string as NSString
        for match in entity.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            guard let whole = Range(match.range, in: string) else { continue }
            result += string[cursor..<whole.lowerBound]
            let name = ns.substring(with: match.range(at: 1))
            result += replacement(for: name) ?? String(string[whole])
            cursor = whole.upperBound
        }
        result += string[cursor...]
        return result
    }

    private static func replacement(for name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            let lower = name.lowercased()
            let code = lower.hasPrefix("#x") ? UInt32(lower.dropFirst(2), radix: 16) : UInt32(lower.dropFirst(1))
            return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }

    // MARK: - Regex plumbing

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals above; one that did not compile would be a
        // programming error caught by the first test.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    /// Each match as its capture groups, group 0 first; an unmatched group is "".
    private static func matches(_ regex: NSRegularExpression, in string: String) -> [[String]] {
        let ns = string as NSString
        return regex.matches(in: string, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }

    private static func replace(_ regex: NSRegularExpression, in string: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: string, range: NSRange(location: 0, length: (string as NSString).length), withTemplate: template)
    }
}

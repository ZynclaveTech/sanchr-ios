import Foundation

/// The link a profile's QR code carries, and the only reader of one.
///
/// Scanning used to be checked twice with two different rules, and the one
/// that actually picked the user out accepted any host ending in the letters
/// `sanchr.com`, any scheme, and anything at all as the id.
enum ProfileLink {

    /// Android encodes exactly this, so either app can read the other's.
    static func link(userId: String) -> String {
        "https://sanchr.com/u/\(userId)"
    }

    /// The user a scanned profile link names, or nil if what was scanned is
    /// not one.
    ///
    /// Strict on purpose, because the answer starts a conversation: it must
    /// be `https`, on `sanchr.com` itself, at `/u/<id>` and nothing more, and
    /// the id must be the shape a user id has. Anything else is some other
    /// QR code.
    static func userId(from scanned: String) -> String? {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), hosts.contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil
        else { return nil }

        let path = parts.percentEncodedPath
        guard path.hasPrefix(prefix) else { return nil }
        let id = path.dropFirst(prefix.count).lowercased()
        return id.range(of: userIdShape, options: .regularExpression) == nil ? nil : id
    }

    private static let prefix = "/u/"
    private static let hosts: Set<String> = ["sanchr.com", "www.sanchr.com"]
    private static let userIdShape = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
}

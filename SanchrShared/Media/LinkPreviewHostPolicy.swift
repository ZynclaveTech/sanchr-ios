import Foundation

/// Which links this device is willing to fetch a preview for.
///
/// The link is in a message, and the message is from someone else, so a
/// preview is a request this device makes on a sender's instruction. That is
/// fine for a site on the internet and not for the device itself or the
/// network it sits on: `http://192.168.1.1/…`, `http://127.0.0.1:8080/…` and
/// their many spellings are all things a link detector will happily find.
///
/// `isFetchable` judges the text of a link. It cannot know that a public name
/// resolves to a private address, or that a public page redirects to one;
/// `isPublicAddress` is for the fetcher to ask those questions of the
/// addresses themselves, on every hop.
public enum LinkPreviewHostPolicy {

    public static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        // `URL.host` is the parsed host: no userinfo, no port, no brackets.
        guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
        // A trailing dot still resolves, and would otherwise slip past every
        // comparison below.
        while host.hasSuffix(".") { host.removeLast() }
        return !isPrivateHost(host)
    }

    /// Whether `literal` — an address a name resolved to, or the peer a
    /// connection actually reached — is a public one. Anything that is not a
    /// plain IPv4 or IPv6 literal is not.
    public static func isPublicAddress(_ literal: String) -> Bool {
        let address = literal.lowercased()
        guard address.contains(":") || dottedQuad(address) != nil else { return false }
        return !isPrivateHost(address)
    }

    static func isPrivateHost(_ host: String) -> Bool {
        if host.contains(":") { return !isPublicIPv6(host) }
        if isNumeric(host) {
            // `0x7f.1`, `2130706433` and `127.1` are loopback to some resolvers
            // and a meaningless string to others. Rather than pick a reading,
            // only the plain four-part form is allowed to continue.
            guard let octets = dottedQuad(host) else { return true }
            return isPrivateIPv4(octets)
        }
        // A bare name is a machine on the local network, or a typo.
        guard host.contains(".") else { return true }
        // `.local` is mDNS; `.internal` and `.home.arpa` are reserved for
        // private networks.
        let privateSuffixes = [".localhost", ".local", ".internal", ".home.arpa"]
        return privateSuffixes.contains { host.hasSuffix($0) }
    }

    /// Every label is decimal or `0x`-hex: an address, not a name. A name with
    /// hex-looking labels — `face.cafe` — is still a name.
    private static func isNumeric(_ host: String) -> Bool {
        host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            if label.isEmpty { return false }
            if label.allSatisfy(\.isASCIIDecimal) { return true }
            let lower = label.lowercased()
            return lower.hasPrefix("0x") && lower.count > 2 && lower.dropFirst(2).allSatisfy(\.isHexDigit)
        }
    }

    private static func dottedQuad(_ host: String) -> [UInt8]? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return nil }
        var octets: [UInt8] = []
        for label in labels {
            // No leading zeros: `0177` is octal to the resolvers that matter.
            guard label.allSatisfy(\.isASCIIDecimal), label.count <= 3,
                  label.count == 1 || label.first != "0",
                  let value = UInt8(label)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isPrivateIPv4(_ o: [UInt8]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _): return true          // this network, private, loopback
        case (169, 254): return true                          // link-local, cloud metadata
        case (172, 16...31): return true                      // private
        case (192, 168): return true                          // private
        case (100, 64...127): return true                     // carrier-grade NAT
        case (224..., _): return true                         // multicast and reserved
        default: return false
        }
    }

    /// IPv6 is allow-listed: only global unicast (2000::/3) is public, which
    /// leaves out loopback, link-local, unique-local, IPv4-mapped and NAT64
    /// forms in one rule. Within it, 6to4 (2002::/16) and Teredo (2001:0::/32)
    /// are refused too — both carry an IPv4 address inside them, so
    /// `2002:7f00:1::` is a way of writing 127.0.0.1.
    private static func isPublicIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        // A zone id (`fe80::1%en0`) is never public.
        guard !host.contains("%"), inet_pton(AF_INET6, host, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard bytes[0] & 0xE0 == 0x20 else { return false }
        let first = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let second = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        if first == 0x2002 { return false }
        if first == 0x2001, second == 0 { return false }
        return true
    }
}

private extension Character {
    var isASCIIDecimal: Bool { isASCII && isNumber && ("0"..."9").contains(self) }
}

import Foundation
import SanchrShared

/// Result of parsing a text-message body that may have been produced by the
/// Task 13 attachment text-fallback path (`ChatDetailViewModel.contactFallbackText` /
/// `locationFallbackText`). The receive side uses this to render a richer
/// in-bubble layout without requiring any proto changes.
enum AttachmentFallback: Equatable {
    case contact(displayName: String)
    case location(latitude: Double, longitude: Double)
}

/// Pure parser for attachment text-fallback messages. Mirrors the formats
/// emitted by `ChatDetailViewModel.contactFallbackText(_:)` and
/// `ChatDetailViewModel.locationFallbackText(_:)`.
///
/// Privacy contract: this parser does NOT touch the network, MapKit, or
/// CoreLocation. It only inspects the message body string.
enum AttachmentFallbackParser {
    private static let contactPrefix = "[Contact] "
    private static let locationPrefix = "[Location] "

    static func parse(_ text: String) -> AttachmentFallback? {
        if text.hasPrefix(contactPrefix) {
            let name = String(text.dropFirst(contactPrefix.count))
            guard !name.isEmpty else { return nil }
            return .contact(displayName: name)
        }

        if text.hasPrefix(locationPrefix) {
            let payload = text.dropFirst(locationPrefix.count)
            let parts = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let lng = Double(parts[1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            return .location(latitude: lat, longitude: lng)
        }

        return nil
    }
}

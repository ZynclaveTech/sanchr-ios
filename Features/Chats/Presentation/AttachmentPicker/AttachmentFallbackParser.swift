import Foundation
import SanchrShared

/// Result of parsing a text-message body that may have been produced by the
/// Task 13 attachment text-fallback path (`ChatDetailViewModel.contactFallbackText` /
/// `locationFallbackText`). The receive side uses this to render a richer
/// in-bubble layout without requiring any proto changes.
enum AttachmentFallback: Equatable {
    /// `phoneNumber` is `nil` for legacy payloads that only carry the
    /// display name, and non-nil for newer payloads that embed a
    /// pipe-delimited E.164 phone (e.g. `[Contact] Jane Doe|+15551234`).
    /// The receiver's bubble viewer only offers phone-dependent actions
    /// (Message-on-Sanchr, Call, SMS, Save, Copy) when the phone is
    /// present.
    case contact(displayName: String, phoneNumber: String?)
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
            let payload = String(text.dropFirst(contactPrefix.count))
            guard !payload.isEmpty else { return nil }
            // Pipe-delimited phone is optional for backward compat with
            // older clients that emitted name-only payloads.
            if let pipeIdx = payload.firstIndex(of: "|") {
                let name = String(payload[..<pipeIdx])
                let phone = String(payload[payload.index(after: pipeIdx)...])
                guard !name.isEmpty else { return nil }
                return .contact(
                    displayName: name,
                    phoneNumber: phone.isEmpty ? nil : phone
                )
            }
            return .contact(displayName: payload, phoneNumber: nil)
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

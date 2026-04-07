import Foundation

/// Tap payload flowing from a rendered `MessageBubble` up through the
/// collection view representable into `ChatDetailViewModel`.
///
/// One enum, one routing switch. Cells never present UI themselves — they
/// fire the interaction and the view model owns the decision of which
/// viewer coordinator to invoke.
public enum MessageInteraction: Sendable, Equatable {
    /// Fired for `.image` and `.video` bubbles. The gallery disambiguates
    /// image vs. video at page-build time so the cell doesn't have to know.
    case openMedia(messageId: String)

    /// Fired for `.contact` bubbles.
    case openContact(name: String, phoneNumber: String)

    /// Fired for `.location` bubbles.
    case openLocation(latitude: Double, longitude: Double)

    /// Fired for `.document` bubbles.
    case openDocument(messageId: String)
}

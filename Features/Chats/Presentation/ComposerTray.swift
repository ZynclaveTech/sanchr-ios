import Foundation

/// The tray showing below the composer, when one is.
///
/// Modelled as a single optional value rather than one boolean per tray.
/// With three independent flags, opening a tray meant remembering to clear
/// the other two at every site that could open one — and one of them was
/// missed: the "+" button cleared the emoji flag but not the sticker flag, so
/// reaching stickers through the attachment sheet and then tapping "+" left
/// the sticker tray and the attachment tray stacked on top of each other.
///
/// A fourth tray would have needed every existing site updated again. Here it
/// is one more case, and exclusivity is a property of the type rather than a
/// convention nobody enforces.
enum ComposerTray: Equatable {
    case attachments
    case emoji
    case stickers
}

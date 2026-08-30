import CoreGraphics
import UIKit
import SanchrShared

/// Everything the context-menu overlay needs to reproduce a long-pressed
/// message on top of the transcript.
///
/// The message is carried as a snapshot rather than re-rendered from its data.
/// Re-rendering would mean threading grouping, upload progress, reply quotes
/// and the rest into a second view and keeping the two in step forever; a
/// snapshot is what was actually on screen, by construction.
struct MessageContextPresentation: Identifiable {
    let id: String
    let message: Message
    /// The cell exactly as it was drawn, at screen scale.
    let snapshot: UIImage
    /// Where that snapshot sat, in the window's coordinate space.
    let sourceFrame: CGRect
    /// Which edge the accessories align to. Outgoing messages sit on the
    /// trailing side, so their menu should too.
    let isOutgoing: Bool
    /// Whether Save/Share/Copy belong in the menu for this message.
    let isSaveableMedia: Bool
    /// Whether a failed send can be retried from here.
    let canRetry: Bool
}

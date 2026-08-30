import SwiftUI
import SanchrShared

/// An entry in the long-press menu.
///
/// Modelled as data rather than built inline so the set of actions for a given
/// message is one decision in one place — testable without presenting anything.
enum MessageContextAction: String, Identifiable, CaseIterable {
    case reply
    case forward
    case copy
    case saveToPhotos
    case share
    case retry
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reply: return "Reply"
        case .forward: return "Forward"
        case .copy: return "Copy"
        case .saveToPhotos: return "Save to Photos"
        case .share: return "Share"
        case .retry: return "Retry"
        case .delete: return "Delete"
        }
    }

    var systemImage: String {
        switch self {
        case .reply: return "arrowshape.turn.up.left"
        case .forward: return "arrowshape.turn.up.right"
        case .copy: return "doc.on.doc"
        case .saveToPhotos: return "square.and.arrow.down"
        case .share: return "square.and.arrow.up"
        case .retry: return "arrow.clockwise"
        case .delete: return "trash"
        }
    }

    var isDestructive: Bool { self == .delete }

    /// Height of one row, used to work out whether the menu fits on screen
    /// before it is drawn.
    static let rowHeight: CGFloat = 48

    static func estimatedMenuHeight(count: Int) -> CGFloat {
        CGFloat(count) * rowHeight + 8
    }

    /// Which actions a message offers.
    ///
    /// Order matters: the two that apply to every message come first, then the
    /// ones that depend on what it is, then the destructive one last and on its
    /// own — a Delete adjacent to Reply is a Delete pressed by accident.
    static func actions(
        isOutgoing: Bool,
        isSaveableMedia: Bool,
        canRetry: Bool,
        isText: Bool
    ) -> [MessageContextAction] {
        var actions: [MessageContextAction] = [.reply, .forward]

        if isSaveableMedia {
            actions.append(contentsOf: [.saveToPhotos, .share])
        }

        // Copy once, whatever it copies. Text and media each used to add their
        // own, so anything that was both listed Copy twice — which a render of
        // the menu showed immediately and no amount of reading would have.
        if isText || isSaveableMedia {
            actions.append(.copy)
        }

        if canRetry {
            actions.append(.retry)
        }

        // Only your own messages can be deleted for everyone, and deleting
        // someone else's copy is not a thing this app can do.
        if isOutgoing {
            actions.append(.delete)
        }

        return actions
    }
}

extension Message.MessageContent {
    /// Whether Copy should offer the message's text.
    var isTextForCopying: Bool {
        if case .text = self { return true }
        return false
    }
}

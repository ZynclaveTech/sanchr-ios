import Foundation

/// Which messages a backup may hold.
///
/// A backup keeps things, somewhere else, for as long as the backup exists.
/// That makes some messages wrong to put in one, however it is protected:
///
/// - a **disappearing** message, which both people were shown a timer for.
///   Backed up, it outlives the timer by as long as the backup does.
/// - **view-once** media, which was sent to be seen once. A backup holds the
///   keys to see it again — and the backup format has nowhere to say "once",
///   so it came back from a restore as an ordinary photo.
///
/// The same rule is applied on the way back in, as far as a backup's own
/// fields allow: one made before this existed, or by an app that does not
/// apply it, may hold both.
public enum BackupMessageRules {

    /// Whether a stored message goes into a backup.
    public static func belongsInBackup(content: Message.MessageContent?, expiresAt: Date?) -> Bool {
        expiresAt == nil && !isViewOnce(content)
    }

    /// Whether a message found in a backup is restored. A deleted message's
    /// placeholder (Android writes those) is not a message.
    public static func mayRestore(_ frame: BackupArchiveMessageFrame) -> Bool {
        frame.expiresAtMs == nil && !frame.isDeleted
    }

    static func isViewOnce(_ content: Message.MessageContent?) -> Bool {
        switch content {
        case .image(let media), .video(let media), .audio(let media), .document(let media):
            return media.items.contains { $0.isViewOnce == true }
        case .text, .location, .contact, .system, .none:
            return false
        }
    }
}

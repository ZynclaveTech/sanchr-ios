import Foundation

/// The "Default Timer" preference from Settings › Chats, which seeds the
/// disappearing-messages duration of new chats the user starts.
///
/// The picker persisted a value from the day it shipped but nothing ever read
/// it, so choosing a default had no effect on any conversation. Conversations
/// store their duration in seconds, so the stored token has to be translated
/// before it can be applied.
public enum DefaultDisappearingTimer {
    public static let storageKey = "sanchr.defaultDisappearingTimer"

    /// Tokens offered by the picker, kept in step with the per-conversation
    /// options in `DisappearingMessagesView` so that every default the user can
    /// choose is a duration a conversation can actually hold.
    private static let secondsByToken: [String: Int64] = [
        "off": 0,
        "5m": 300,
        "1h": 3600,
        "24h": 86400,
        "7d": 604_800,
        "30d": 2_592_000,
    ]

    /// Seconds for a stored token; 0 (off) for anything unrecognised, so a
    /// stale value written by another build never silently enables
    /// disappearing messages on a new chat.
    public static func seconds(forToken token: String) -> Int64 {
        secondsByToken[token] ?? 0
    }

    /// The user's current default, in seconds. 0 means "off".
    public static var seconds: Int64 {
        guard let token = UserDefaults.standard.string(forKey: storageKey) else { return 0 }
        return seconds(forToken: token)
    }
}

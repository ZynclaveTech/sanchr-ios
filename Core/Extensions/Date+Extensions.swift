import Foundation

extension Date {
    // MARK: - Chat Formatting

    /// Returns a relative chat timestamp: "Just now", "5m", "2h", "Yesterday", or date.
    var chatTimestamp: String {
        let now = Date()
        let interval = now.timeIntervalSince(self)

        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else if interval < 86400, Calendar.current.isDateInToday(self) {
            return "\(Int(interval / 3600))h"
        } else if Calendar.current.isDateInYesterday(self) {
            return "Yesterday"
        } else if interval < 604_800 {
            return Self.dayOfWeekFormatter.string(from: self)
        } else {
            return Self.shortDateFormatter.string(from: self)
        }
    }

    /// Returns time-only string: "2:30 PM".
    var messageTime: String {
        Self.timeFormatter.string(from: self)
    }

    /// Returns call duration string: "1:23" or "0:05".
    static func callDuration(seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - Formatters (cached)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let dayOfWeekFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()
}

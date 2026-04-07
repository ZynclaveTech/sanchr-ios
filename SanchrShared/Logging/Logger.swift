import Foundation
import os

/// Centralized logging wrapper using Apple's unified logging system.
/// Categorized loggers ensure structured, filterable output in Console.app.
enum SanchrLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.sanchr.app"

    /// General app lifecycle events.
    static let app = Logger(subsystem: subsystem, category: "App")

    /// Authentication and session events.
    static let auth = Logger(subsystem: subsystem, category: "Auth")

    /// Networking and gRPC calls.
    static let network = Logger(subsystem: subsystem, category: "Network")

    /// Encryption and key management operations.
    static let crypto = Logger(subsystem: subsystem, category: "Crypto")

    /// Chat and messaging events.
    static let chat = Logger(subsystem: subsystem, category: "Chat")

    /// WebRTC and call events.
    static let calls = Logger(subsystem: subsystem, category: "Calls")

    /// Database and persistence operations.
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")

    /// Push notifications.
    static let push = Logger(subsystem: subsystem, category: "Push")

    /// Media processing (capture, compression, encryption).
    static let media = Logger(subsystem: subsystem, category: "Media")

    /// Background sync operations.
    static let sync = Logger(subsystem: subsystem, category: "Sync")

    /// Privacy and user settings operations.
    static let settings = Logger(subsystem: subsystem, category: "Settings")
}

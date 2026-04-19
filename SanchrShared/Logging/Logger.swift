import Foundation
import os

/// Centralized logging wrapper using Apple's unified logging system.
/// Categorized loggers ensure structured, filterable output in Console.app.
public enum SanchrLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.sanchr.app"

    /// General app lifecycle events.
    public static let app = Logger(subsystem: subsystem, category: "App")

    /// Authentication and session events.
    public static let auth = Logger(subsystem: subsystem, category: "Auth")

    /// Networking and gRPC calls.
    public static let network = Logger(subsystem: subsystem, category: "Network")

    /// Encryption and key management operations.
    public static let crypto = Logger(subsystem: subsystem, category: "Crypto")

    /// Chat and messaging events.
    public static let chat = Logger(subsystem: subsystem, category: "Chat")

    /// WebRTC and call events.
    public static let calls = Logger(subsystem: subsystem, category: "Calls")

    /// Database and persistence operations.
    public static let persistence = Logger(subsystem: subsystem, category: "Persistence")

    /// Push notifications.
    public static let push = Logger(subsystem: subsystem, category: "Push")

    /// Media processing (capture, compression, encryption).
    public static let media = Logger(subsystem: subsystem, category: "Media")

    /// Background sync operations.
    public static let sync = Logger(subsystem: subsystem, category: "Sync")

    /// Privacy and user settings operations.
    public static let settings = Logger(subsystem: subsystem, category: "Settings")

    /// Contact discovery and management events.
    public static let contacts = Logger(subsystem: subsystem, category: "Contacts")

    /// Vault and EKF scheduler operations.
    public static let vault = Logger(subsystem: subsystem, category: "Vault")

    /// UI-layer warnings (cell cast failures, unexpected view states, etc.).
    public static let ui = Logger(subsystem: subsystem, category: "UI")

    /// Security and trust-chain events (TLS pinning, app lock, keychain).
    public static let security = Logger(subsystem: subsystem, category: "Security")
}

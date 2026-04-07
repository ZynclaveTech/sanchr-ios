import Foundation

/// Environment-aware configuration providing API URLs, feature flags,
/// and build-specific settings.
public struct AppConfiguration: Sendable {
    public enum Environment: String, Sendable {
        case development
        case dev
        case staging
        case production
    }

    public let environment: Environment
    public let grpcHost: String
    public let grpcPort: Int
    public let callHost: String
    public let callPort: Int
    public let useTLS: Bool
    public let mediaBaseURL: URL
    public let stunServers: [String]
    public let turnServers: [String]

    // MARK: - Feature Flags

    public let isVaultEnabled: Bool
    public let isVideoCallEnabled: Bool
    public let isDisappearingMessagesEnabled: Bool
    public let maxMediaUploadSizeMB: Int

    public init(
        environment: Environment,
        grpcHost: String,
        grpcPort: Int,
        callHost: String,
        callPort: Int,
        useTLS: Bool,
        mediaBaseURL: URL,
        stunServers: [String],
        turnServers: [String],
        isVaultEnabled: Bool,
        isVideoCallEnabled: Bool,
        isDisappearingMessagesEnabled: Bool,
        maxMediaUploadSizeMB: Int
    ) {
        self.environment = environment
        self.grpcHost = grpcHost
        self.grpcPort = grpcPort
        self.callHost = callHost
        self.callPort = callPort
        self.useTLS = useTLS
        self.mediaBaseURL = mediaBaseURL
        self.stunServers = stunServers
        self.turnServers = turnServers
        self.isVaultEnabled = isVaultEnabled
        self.isVideoCallEnabled = isVideoCallEnabled
        self.isDisappearingMessagesEnabled = isDisappearingMessagesEnabled
        self.maxMediaUploadSizeMB = maxMediaUploadSizeMB
    }

    // MARK: - Factory

    public static var current: AppConfiguration {
        #if DEBUG
            return .dev
        #else
            return .production
        #endif
    }

    public static let development = AppConfiguration(
        environment: .development,
        grpcHost: "localhost",
        grpcPort: 50051,
        callHost: "localhost",
        callPort: 50052,
        useTLS: false,
        mediaBaseURL: URL(string: "http://localhost:8080/media")!,
        stunServers: ["stun:stun.l.google.com:19302"],
        turnServers: [],
        isVaultEnabled: true,
        isVideoCallEnabled: true,
        isDisappearingMessagesEnabled: true,
        maxMediaUploadSizeMB: 100
    )

    public static let dev = AppConfiguration(
        environment: .dev,
        grpcHost: "api-dev.sanchr.com",
        grpcPort: 443,
        callHost: "call-dev.sanchr.com",
        callPort: 443,
        useTLS: true,
        mediaBaseURL: URL(string: "https://media-dev.sanchr.com")!,
        stunServers: ["stun:stun.l.google.com:19302"],
        turnServers: [],
        isVaultEnabled: true,
        isVideoCallEnabled: true,
        isDisappearingMessagesEnabled: true,
        maxMediaUploadSizeMB: 100
    )

    public static let staging = AppConfiguration(
        environment: .staging,
        grpcHost: "api-staging.sanchr.io",
        grpcPort: 443,
        callHost: "call-staging.sanchr.io",
        callPort: 443,
        useTLS: true,
        mediaBaseURL: URL(string: "https://media-staging.sanchr.io")!,
        stunServers: ["stun:stun.l.google.com:19302"],
        turnServers: [],
        isVaultEnabled: true,
        isVideoCallEnabled: true,
        isDisappearingMessagesEnabled: true,
        maxMediaUploadSizeMB: 50
    )

    public static let production = AppConfiguration(
        environment: .production,
        grpcHost: "api.sanchr.io",
        grpcPort: 443,
        callHost: "call.sanchr.io",
        callPort: 443,
        useTLS: true,
        mediaBaseURL: URL(string: "https://media.sanchr.io")!,
        stunServers: [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302",
        ],
        turnServers: [
            // TODO: Configure production TURN servers
        ],
        isVaultEnabled: true,
        isVideoCallEnabled: false,  // TODO: Enable after beta testing
        isDisappearingMessagesEnabled: true,
        maxMediaUploadSizeMB: 25
    )
}

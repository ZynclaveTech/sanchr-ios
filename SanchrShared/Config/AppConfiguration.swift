import Foundation

/// Environment-aware configuration providing API URLs, feature flags,
/// and build-specific settings.
struct AppConfiguration: Sendable {
    enum Environment: String, Sendable {
        case development
        case dev
        case staging
        case production
    }

    let environment: Environment
    let grpcHost: String
    let grpcPort: Int
    let callHost: String
    let callPort: Int
    let useTLS: Bool
    let mediaBaseURL: URL
    let stunServers: [String]
    let turnServers: [String]

    // MARK: - Feature Flags

    let isVaultEnabled: Bool
    let isVideoCallEnabled: Bool
    let isDisappearingMessagesEnabled: Bool
    let maxMediaUploadSizeMB: Int

    // MARK: - Factory

    static var current: AppConfiguration {
        #if DEBUG
            return .dev
        #else
            return .production
        #endif
    }

    static let development = AppConfiguration(
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

    static let dev = AppConfiguration(
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

    static let staging = AppConfiguration(
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

    static let production = AppConfiguration(
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

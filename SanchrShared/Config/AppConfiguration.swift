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
    /// STUN servers used by `CallManager.buildIceServers` as the always-on
    /// fallback alongside any TURN credentials returned from the server. Each
    /// environment may declare its own list. TURN credentials remain server-issued
    /// via `CallSignalingService.GetTurnCredentials` and MUST NOT be hard-coded.
    public let stunServers: [String]

    // MARK: - TLS Certificate Pinning

    /// SHA-256 hash of the gRPC server's TLS certificate (DER format, base64-encoded)
    public let grpcCertificateHash: String?

    /// SHA-256 hash of the call signaling server's TLS certificate (DER format, base64-encoded)
    public let callCertificateHash: String?

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
        isVaultEnabled: Bool,
        isVideoCallEnabled: Bool,
        isDisappearingMessagesEnabled: Bool,
        maxMediaUploadSizeMB: Int,
        grpcCertificateHash: String? = nil,
        callCertificateHash: String? = nil
    ) {
        self.environment = environment
        self.grpcHost = grpcHost
        self.grpcPort = grpcPort
        self.callHost = callHost
        self.callPort = callPort
        self.useTLS = useTLS
        self.mediaBaseURL = mediaBaseURL
        self.stunServers = stunServers
        self.isVaultEnabled = isVaultEnabled
        self.isVideoCallEnabled = isVideoCallEnabled
        self.isDisappearingMessagesEnabled = isDisappearingMessagesEnabled
        self.maxMediaUploadSizeMB = maxMediaUploadSizeMB
        self.grpcCertificateHash = grpcCertificateHash
        self.callCertificateHash = callCertificateHash
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
        isVaultEnabled: true,
        isVideoCallEnabled: true,
        isDisappearingMessagesEnabled: true,
        maxMediaUploadSizeMB: 100
    )

    public static let dev = AppConfiguration(
        environment: .dev,
        grpcHost: "api.sanchr.com",
        grpcPort: 443,
        callHost: "call.sanchr.com",
        callPort: 443,
        useTLS: true,
        mediaBaseURL: URL(string: "https://sanchr-media.sfo3.digitaloceanspaces.com")!,
        stunServers: ["stun:stun.l.google.com:19302"],
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
        isVaultEnabled: true,
        isVideoCallEnabled: false,  // TODO: Enable after beta testing
        isDisappearingMessagesEnabled: true,
        maxMediaUploadSizeMB: 25,
        // TODO: Obtain actual certificate hashes from backend certificates
        // openssl s_client -connect api.sanchr.io:443 -showcerts </dev/null 2>/dev/null | openssl x509 -outform DER | openssl dgst -sha256 -binary | base64
        grpcCertificateHash: nil,
        callCertificateHash: nil
    )
}

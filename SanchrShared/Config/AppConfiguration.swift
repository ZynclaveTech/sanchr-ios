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

    /// Base64 SHA-256 pins of accepted `SubjectPublicKeyInfo` values for the API
    /// host. A connection is accepted when any certificate in the presented chain
    /// matches one of these.
    ///
    /// Empty disables pinning. Ship at least two — the current leaf key and a
    /// backup (an intermediate, or a pre-generated next key) — so that rotating
    /// the server key does not require every client to update first.
    ///
    /// Generate with `Scripts/generate-cert-pins.sh <host>`.
    public let grpcCertificatePins: Set<String>

    /// Same, for the call signaling host.
    public let callCertificatePins: Set<String>

    // MARK: - Feature Flags

    public let isVaultEnabled: Bool
    /// When `false`, `CallManager` refuses to start a video call (throws
    /// `AppError.featureDisabled`) and `requestVideoUpgrade()` becomes a no-op.
    /// The chat / calls UI hides the "start video call" CTA in the same state.
    /// This is the single gate — do not add duplicate checks in higher layers.
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
        grpcCertificatePins: Set<String> = [],
        callCertificatePins: Set<String> = []
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
        self.grpcCertificatePins = grpcCertificatePins
        self.callCertificatePins = callCertificatePins
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
        // .com, not .io: api.sanchr.io and call.sanchr.io resolve to nothing and
        // serve no certificate, while the deployed ingress (deploy/do/values-production.yaml)
        // is api.sanchr.com / call.sanchr.com. Release builds were pointing at
        // hosts that do not exist.
        grpcHost: "api.sanchr.com",
        grpcPort: 443,
        callHost: "call.sanchr.com",
        callPort: 443,
        useTLS: true,
        // media.sanchr.io and media.sanchr.com both resolve to nothing. The
        // deployed bucket is sanchr-media on sfo3 with an empty cdn_base_url
        // (backend deploy/do/values-production.yaml), so objects are served
        // straight from Spaces — same as dev.
        mediaBaseURL: URL(string: "https://sanchr-media.sfo3.digitaloceanspaces.com")!,
        stunServers: [
            "stun:stun.l.google.com:19302",
            "stun:stun1.l.google.com:19302",
        ],
        isVaultEnabled: true,
        isVideoCallEnabled: false,  // TODO: Enable after beta testing
        isDisappearingMessagesEnabled: true,
        maxMediaUploadSizeMB: 25,
        // Captured from the live chain with Scripts/generate-cert-pins.sh.
        // Leaf first, then the Let's Encrypt intermediate and ISRG root as
        // backups: if the server key rotates, the chain still matches a pinned
        // CA and clients stay online instead of being locked out until they
        // update. Re-run the script and refresh these when the chain changes.
        grpcCertificatePins: [
            "yd5ZAf28dpfRN+w7znX6CTeF28OpmFeDdEt0B3yQm+s=",  // leaf CN=api.sanchr.com
            "LoMHBotttiDko50Gi13uXW71eIy7LAttI+rYT8wXF4w=",  // Let's Encrypt YR1
            "fk6IOKit1ild5647BH06ujSIq5XbCgqlbYl6ANhhi88=",  // ISRG Root YR
        ],
        callCertificatePins: [
            "fCNvolsAMHRlvELT9i54m9mvKvsyY2kBzATIy942jeQ=",  // leaf CN=call.sanchr.com
            "nWN7PSep5XDQdge5zK24CnCRXHr3KvzhKEGxsdqCX9E=",  // Let's Encrypt YR2
            "fk6IOKit1ild5647BH06ujSIq5XbCgqlbYl6ANhhi88=",  // ISRG Root YR
        ]
    )
}

import Foundation
import GRPC
import NIOCore
import NIOPosix
import NIOSSL

/// Protocol for the gRPC client manager abstraction.
public protocol GRPCClientProtocol: Sendable {
    /// Establishes both core and call gRPC channels.
    func connect() async throws

    /// Closes all gRPC channels gracefully.
    func disconnect() async throws

    /// Whether the core channel is currently connected.
    var isConnected: Bool { get }

    // MARK: - Core Service Clients

    var authService: Sanchr_Auth_AuthServiceAsyncClientProtocol { get }
    var messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol { get }
    var contactService: Sanchr_Contacts_ContactServiceAsyncClientProtocol { get }
    var keyService: Sanchr_Keys_KeyServiceAsyncClientProtocol { get }
    var mediaService: Sanchr_Media_MediaServiceAsyncClientProtocol { get }
    var settingsService: Sanchr_Settings_SettingsServiceAsyncClientProtocol { get }
    var notificationService: Sanchr_Notifications_NotificationServiceAsyncClientProtocol { get }
    var vaultService: Sanchr_Vault_VaultServiceAsyncClientProtocol { get }
    var backupService: Sanchr_Backup_BackupServiceAsyncClientProtocol { get }
    var discoveryService: Sanchr_Discovery_DiscoveryServiceAsyncClientProtocol { get }

    // MARK: - Call Service Client (separate channel)

    var callSignalingService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol { get }
}

/// gRPC channel manager wrapping connection lifecycle and typed service stubs.
/// Maintains two channels: `coreChannel` for most services and `callChannel`
/// for call signaling, pointing at separate backend hosts.
///
/// Channels and service clients are created eagerly in `init`. grpc-swift's
/// `ClientConnection` is itself lazy — it only opens the TCP connection on the
/// first RPC — so creating them early is safe and avoids "accessed before
/// connect()" crashes from lazy DI containers.  `connect()` is still provided
/// for explicit lifecycle control and logging.
public final class SanchrGRPCClient: GRPCClientProtocol, @unchecked Sendable {
    private let configuration: AppConfiguration
    private let group: EventLoopGroup
    private let coreChannel: ClientConnection
    private let callChannel: ClientConnection

    public var isConnected: Bool {
        coreChannel.connectivity.state == .ready || callChannel.connectivity.state == .ready
    }

    // MARK: - Service clients (created eagerly)

    public let authService: Sanchr_Auth_AuthServiceAsyncClientProtocol
    public let messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol
    public let contactService: Sanchr_Contacts_ContactServiceAsyncClientProtocol
    public let keyService: Sanchr_Keys_KeyServiceAsyncClientProtocol
    public let mediaService: Sanchr_Media_MediaServiceAsyncClientProtocol
    public let settingsService: Sanchr_Settings_SettingsServiceAsyncClientProtocol
    public let notificationService: Sanchr_Notifications_NotificationServiceAsyncClientProtocol
    public let vaultService: Sanchr_Vault_VaultServiceAsyncClientProtocol
    public let backupService: Sanchr_Backup_BackupServiceAsyncClientProtocol
    public let discoveryService: Sanchr_Discovery_DiscoveryServiceAsyncClientProtocol
    public let callSignalingService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol

    // MARK: - Init

    public init(
        configuration: AppConfiguration,
        authInterceptors: AuthInterceptorFactory? = nil
    ) {
        self.configuration = configuration

        let elg = PlatformSupport.makeEventLoopGroup(loopCount: 1)
        self.group = elg

        // Build channels (lazy-connect — no TCP until first RPC)
        let coreConn = Self.buildChannel(
            group: elg,
            host: configuration.grpcHost,
            port: configuration.grpcPort,
            useTLS: configuration.useTLS
        )
        self.coreChannel = coreConn

        let callConn = Self.buildChannel(
            group: elg,
            host: configuration.callHost,
            port: configuration.callPort,
            useTLS: configuration.useTLS
        )
        self.callChannel = callConn

        // Core service clients
        authService = Sanchr_Auth_AuthServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        messagingService = Sanchr_Messaging_MessagingServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        contactService = Sanchr_Contacts_ContactServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        keyService = Sanchr_Keys_KeyServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        mediaService = Sanchr_Media_MediaServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        settingsService = Sanchr_Settings_SettingsServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        notificationService = Sanchr_Notifications_NotificationServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        vaultService = Sanchr_Vault_VaultServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        backupService = Sanchr_Backup_BackupServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        discoveryService = Sanchr_Discovery_DiscoveryServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )

        // Call signaling on dedicated channel
        callSignalingService = Sanchr_Calling_CallSignalingServiceAsyncClient(
            channel: callConn, interceptors: authInterceptors
        )
    }

    // MARK: - Connection Lifecycle

    public func connect() async throws {
        let config = self.configuration
        SanchrLogger.network.info(
            "Connecting gRPC: core=\(config.grpcHost):\(config.grpcPort), call=\(config.callHost):\(config.callPort)"
        )
        SanchrLogger.network.info(
            "gRPC channels prepared: coreState=\(String(describing: self.coreChannel.connectivity.state)), callState=\(String(describing: self.callChannel.connectivity.state))"
        )
    }

    public func disconnect() async throws {
        SanchrLogger.network.info("Disconnecting gRPC channels")

        let coreClose = coreChannel.close()
        let callClose = callChannel.close()

        _ = try? await coreClose.get()
        _ = try? await callClose.get()

        let groupToShutdown = group
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    try groupToShutdown.syncShutdownGracefully()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    deinit {
        _ = try? coreChannel.close().wait()
        _ = try? callChannel.close().wait()
        try? group.syncShutdownGracefully()
    }

    // MARK: - Channel Builder

    private static func buildChannel(
        group: EventLoopGroup,
        host: String,
        port: Int,
        useTLS: Bool
    ) -> ClientConnection {
        let builder: ClientConnection.Builder
        if useTLS {
            builder = ClientConnection.usingPlatformAppropriateTLS(for: group)
        } else {
            builder = ClientConnection.insecure(group: group)
        }

        let keepalive = ClientConnectionKeepalive(
            interval: .seconds(30),
            timeout: .seconds(10)
        )

        return builder
            .withConnectionTimeout(minimum: .seconds(10))
            .withConnectionBackoff(initial: .milliseconds(100))
            .withKeepalive(keepalive)
            .connect(host: host, port: port)
    }
}

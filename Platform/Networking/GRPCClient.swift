import Foundation
import GRPC
import NIOCore
import NIOPosix
import NIOSSL
import SanchrShared

/// Protocol for the gRPC client manager abstraction.
protocol GRPCClientProtocol: Sendable {
    /// Establishes both core and call gRPC channels.
    func connect() async throws

    /// Closes all gRPC channels gracefully.
    func disconnect() async throws

    /// Whether the core channel is currently connected.
    var isConnected: Bool { get }

    // MARK: - Core Service Clients

    var authService: Vync_Auth_AuthServiceAsyncClientProtocol { get }
    var messagingService: Vync_Messaging_MessagingServiceAsyncClientProtocol { get }
    var contactService: Vync_Contacts_ContactServiceAsyncClientProtocol { get }
    var keyService: Vync_Keys_KeyServiceAsyncClientProtocol { get }
    var mediaService: Vync_Media_MediaServiceAsyncClientProtocol { get }
    var settingsService: Vync_Settings_SettingsServiceAsyncClientProtocol { get }
    var notificationService: Vync_Notifications_NotificationServiceAsyncClientProtocol { get }
    var vaultService: Vync_Vault_VaultServiceAsyncClientProtocol { get }
    var backupService: Vync_Backup_BackupServiceAsyncClientProtocol { get }
    var discoveryService: Vync_Discovery_DiscoveryServiceAsyncClientProtocol { get }

    // MARK: - Call Service Client (separate channel)

    var callSignalingService: Vync_Calling_CallSignalingServiceAsyncClientProtocol { get }
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
final class SanchrGRPCClient: GRPCClientProtocol, @unchecked Sendable {
    private let configuration: AppConfiguration
    private let group: EventLoopGroup
    private let coreChannel: ClientConnection
    private let callChannel: ClientConnection

    var isConnected: Bool {
        coreChannel.connectivity.state == .ready || callChannel.connectivity.state == .ready
    }

    // MARK: - Service clients (created eagerly)

    let authService: Vync_Auth_AuthServiceAsyncClientProtocol
    let messagingService: Vync_Messaging_MessagingServiceAsyncClientProtocol
    let contactService: Vync_Contacts_ContactServiceAsyncClientProtocol
    let keyService: Vync_Keys_KeyServiceAsyncClientProtocol
    let mediaService: Vync_Media_MediaServiceAsyncClientProtocol
    let settingsService: Vync_Settings_SettingsServiceAsyncClientProtocol
    let notificationService: Vync_Notifications_NotificationServiceAsyncClientProtocol
    let vaultService: Vync_Vault_VaultServiceAsyncClientProtocol
    let backupService: Vync_Backup_BackupServiceAsyncClientProtocol
    let discoveryService: Vync_Discovery_DiscoveryServiceAsyncClientProtocol
    let callSignalingService: Vync_Calling_CallSignalingServiceAsyncClientProtocol

    // MARK: - Init

    init(
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
        authService = Vync_Auth_AuthServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        messagingService = Vync_Messaging_MessagingServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        contactService = Vync_Contacts_ContactServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        keyService = Vync_Keys_KeyServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        mediaService = Vync_Media_MediaServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        settingsService = Vync_Settings_SettingsServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        notificationService = Vync_Notifications_NotificationServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        vaultService = Vync_Vault_VaultServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        backupService = Vync_Backup_BackupServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )
        discoveryService = Vync_Discovery_DiscoveryServiceAsyncClient(
            channel: coreConn, interceptors: authInterceptors
        )

        // Call signaling on dedicated channel
        callSignalingService = Vync_Calling_CallSignalingServiceAsyncClient(
            channel: callConn, interceptors: authInterceptors
        )
    }

    // MARK: - Connection Lifecycle

    func connect() async throws {
        let config = self.configuration
        SanchrLogger.network.info(
            "Connecting gRPC: core=\(config.grpcHost):\(config.grpcPort), call=\(config.callHost):\(config.callPort)"
        )
        SanchrLogger.network.info(
            "gRPC channels prepared: coreState=\(String(describing: self.coreChannel.connectivity.state)), callState=\(String(describing: self.callChannel.connectivity.state))"
        )
    }

    func disconnect() async throws {
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

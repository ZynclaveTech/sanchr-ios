import Foundation
import GRPC
import NIOCore
import NIOPosix
import NIOSSL

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

    // MARK: - Call Service Client (separate channel)

    var callSignalingService: Vync_Calling_CallSignalingServiceAsyncClientProtocol { get }
}

/// gRPC channel manager wrapping connection lifecycle and typed service stubs.
/// Maintains two channels: `coreChannel` for most services and `callChannel`
/// for call signaling, pointing at separate backend hosts.
final class GRPCClient: GRPCClientProtocol, @unchecked Sendable {
    private let configuration: AppConfiguration
    private var group: EventLoopGroup?
    private var coreChannel: ClientConnection?
    private var callChannel: ClientConnection?

    private(set) var isConnected: Bool = false

    // MARK: - Interceptor factories

    private let authInterceptors: AuthInterceptorFactory?

    // MARK: - Lazy service clients (created after connect)

    private var _authService: Vync_Auth_AuthServiceAsyncClient?
    private var _messagingService: Vync_Messaging_MessagingServiceAsyncClient?
    private var _contactService: Vync_Contacts_ContactServiceAsyncClient?
    private var _keyService: Vync_Keys_KeyServiceAsyncClient?
    private var _mediaService: Vync_Media_MediaServiceAsyncClient?
    private var _settingsService: Vync_Settings_SettingsServiceAsyncClient?
    private var _notificationService: Vync_Notifications_NotificationServiceAsyncClient?
    private var _vaultService: Vync_Vault_VaultServiceAsyncClient?
    private var _callSignalingService: Vync_Calling_CallSignalingServiceAsyncClient?

    // MARK: - Protocol accessors

    var authService: Vync_Auth_AuthServiceAsyncClientProtocol {
        guard let client = _authService else {
            fatalError("GRPCClient: authService accessed before connect()")
        }
        return client
    }

    var messagingService: Vync_Messaging_MessagingServiceAsyncClientProtocol {
        guard let client = _messagingService else {
            fatalError("GRPCClient: messagingService accessed before connect()")
        }
        return client
    }

    var contactService: Vync_Contacts_ContactServiceAsyncClientProtocol {
        guard let client = _contactService else {
            fatalError("GRPCClient: contactService accessed before connect()")
        }
        return client
    }

    var keyService: Vync_Keys_KeyServiceAsyncClientProtocol {
        guard let client = _keyService else {
            fatalError("GRPCClient: keyService accessed before connect()")
        }
        return client
    }

    var mediaService: Vync_Media_MediaServiceAsyncClientProtocol {
        guard let client = _mediaService else {
            fatalError("GRPCClient: mediaService accessed before connect()")
        }
        return client
    }

    var settingsService: Vync_Settings_SettingsServiceAsyncClientProtocol {
        guard let client = _settingsService else {
            fatalError("GRPCClient: settingsService accessed before connect()")
        }
        return client
    }

    var notificationService: Vync_Notifications_NotificationServiceAsyncClientProtocol {
        guard let client = _notificationService else {
            fatalError("GRPCClient: notificationService accessed before connect()")
        }
        return client
    }

    var vaultService: Vync_Vault_VaultServiceAsyncClientProtocol {
        guard let client = _vaultService else {
            fatalError("GRPCClient: vaultService accessed before connect()")
        }
        return client
    }

    var callSignalingService: Vync_Calling_CallSignalingServiceAsyncClientProtocol {
        guard let client = _callSignalingService else {
            fatalError("GRPCClient: callSignalingService accessed before connect()")
        }
        return client
    }

    // MARK: - Init

    init(
        configuration: AppConfiguration,
        authInterceptors: AuthInterceptorFactory? = nil
    ) {
        self.configuration = configuration
        self.authInterceptors = authInterceptors
    }

    // MARK: - Connection Lifecycle

    func connect() async throws {
        SanchrLogger.network.info(
            "Connecting gRPC: core=\(configuration.grpcHost):\(configuration.grpcPort), call=\(configuration.callHost):\(configuration.callPort)"
        )

        let elg = PlatformSupport.makeEventLoopGroup(loopCount: 1)
        self.group = elg

        // Build the core channel
        let coreConn = Self.buildChannel(
            group: elg,
            host: configuration.grpcHost,
            port: configuration.grpcPort,
            useTLS: configuration.useTLS
        )
        self.coreChannel = coreConn

        // Build the call signaling channel
        let callConn = Self.buildChannel(
            group: elg,
            host: configuration.callHost,
            port: configuration.callPort,
            useTLS: configuration.useTLS
        )
        self.callChannel = callConn

        // Initialize service clients on the core channel
        _authService = Vync_Auth_AuthServiceAsyncClient(
            channel: coreConn,
            interceptors: authInterceptors
        )
        _messagingService = Vync_Messaging_MessagingServiceAsyncClient(
            channel: coreConn,
            interceptors: authInterceptors
        )
        _contactService = Vync_Contacts_ContactServiceAsyncClient(
            channel: coreConn,
            interceptors: authInterceptors
        )
        _keyService = Vync_Keys_KeyServiceAsyncClient(
            channel: coreConn,
            interceptors: authInterceptors
        )
        _mediaService = Vync_Media_MediaServiceAsyncClient(
            channel: coreConn,
            interceptors: authInterceptors
        )
        _settingsService = Vync_Settings_SettingsServiceAsyncClient(
            channel: coreConn,
            interceptors: authInterceptors
        )
        _notificationService = Vync_Notifications_NotificationServiceAsyncClient(
            channel: coreConn,
            interceptors: authInterceptors
        )
        _vaultService = Vync_Vault_VaultServiceAsyncClient(
            channel: coreConn,
            interceptors: authInterceptors
        )

        // Call signaling on the dedicated call channel
        _callSignalingService = Vync_Calling_CallSignalingServiceAsyncClient(
            channel: callConn,
            interceptors: authInterceptors
        )

        isConnected = true
        SanchrLogger.network.info("gRPC channels established")
    }

    func disconnect() async throws {
        SanchrLogger.network.info("Disconnecting gRPC channels")

        let coreClose = coreChannel?.close()
        let callClose = callChannel?.close()

        _ = try? coreClose?.wait()
        _ = try? callClose?.wait()

        try? group?.syncShutdownGracefully()

        coreChannel = nil
        callChannel = nil
        group = nil
        isConnected = false
    }

    deinit {
        _ = try? coreChannel?.close().wait()
        _ = try? callChannel?.close().wait()
        try? group?.syncShutdownGracefully()
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

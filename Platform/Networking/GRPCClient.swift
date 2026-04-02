import Foundation

// TODO: Import GRPC and NIOCore when grpc-swift is resolved via SPM
// import GRPC
// import NIOCore
// import NIOPosix

/// Protocol for the gRPC client abstraction.
protocol GRPCClientProtocol: Sendable {
    /// Establishes the gRPC channel connection.
    func connect() async throws

    /// Closes the gRPC channel gracefully.
    func disconnect() async throws

    /// Whether the channel is currently connected.
    var isConnected: Bool { get }

    // TODO: Add typed service stubs for each backend service
    // var authService: AuthServiceClientProtocol { get }
    // var messagingService: MessagingServiceClientProtocol { get }
    // var contactService: ContactServiceClientProtocol { get }
    // var callService: CallServiceClientProtocol { get }
    // var vaultService: VaultServiceClientProtocol { get }
}

/// gRPC channel wrapper managing connection lifecycle and service stubs.
final class GRPCClient: GRPCClientProtocol, @unchecked Sendable {
    private let configuration: AppConfiguration
    // private var group: EventLoopGroup?
    // private var channel: GRPCChannel?

    private(set) var isConnected: Bool = false

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func connect() async throws {
        SanchrLogger.network.info("Connecting to gRPC server at \(self.configuration.grpcHost):\(self.configuration.grpcPort)")

        // TODO: Implement gRPC channel setup
        // group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
        //
        // let builder: ClientConnection.Builder
        // if configuration.useTLS {
        //     builder = ClientConnection.usingPlatformAppropriateTLS(for: group!)
        // } else {
        //     builder = ClientConnection.insecure(group: group!)
        // }
        //
        // channel = builder
        //     .withConnectionTimeout(minimum: .seconds(10))
        //     .withConnectionBackoff(initial: .milliseconds(100))
        //     .connect(host: configuration.grpcHost, port: configuration.grpcPort)
        //
        // isConnected = true

        SanchrLogger.network.info("gRPC channel established")
    }

    func disconnect() async throws {
        SanchrLogger.network.info("Disconnecting gRPC channel")

        // TODO: Graceful shutdown
        // try? channel?.close().wait()
        // try? group?.syncShutdownGracefully()
        // channel = nil
        // group = nil

        isConnected = false
    }

    deinit {
        // TODO: Ensure channel is closed
    }
}

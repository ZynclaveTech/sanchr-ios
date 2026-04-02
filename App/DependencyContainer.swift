import SwiftUI

/// Protocol-based dependency injection container.
/// All services are lazily initialized and shared across the app.
@Observable
final class DependencyContainer {

    // MARK: - Platform Services

    lazy var keychainService: KeychainServiceProtocol = KeychainService()

    lazy var secureStorage: SecureStorageProtocol = SecureStorage(
        keychain: keychainService
    )

    lazy var networkMonitor: NetworkMonitorProtocol = NetworkMonitor()

    lazy var grpcClient: GRPCClientProtocol = GRPCClient(
        configuration: appConfiguration
    )

    lazy var localDatabase: LocalDatabaseProtocol = LocalDatabase()

    // MARK: - Crypto

    lazy var keyManager: KeyManagerProtocol = KeyManager(
        secureStorage: secureStorage
    )

    lazy var signalProtocol: SignalProtocolManagerProtocol = SignalProtocolManager(
        keyManager: keyManager,
        secureStorage: secureStorage
    )

    lazy var mediaEncryption: MediaEncryptionProtocol = MediaEncryption()

    // MARK: - Repositories

    lazy var authRepository: AuthRepositoryProtocol = AuthRepositoryImpl(
        grpcClient: grpcClient,
        secureStorage: secureStorage
    )

    lazy var messageRepository: MessageRepositoryProtocol = MessageRepositoryImpl(
        grpcClient: grpcClient,
        localDatabase: localDatabase,
        signalProtocol: signalProtocol
    )

    lazy var contactRepository: ContactRepositoryProtocol = ContactRepositoryImpl(
        grpcClient: grpcClient,
        localDatabase: localDatabase
    )

    lazy var vaultRepository: VaultRepositoryProtocol = VaultRepositoryImpl(
        grpcClient: grpcClient,
        localDatabase: localDatabase,
        mediaEncryption: mediaEncryption
    )

    // MARK: - Services

    lazy var sessionService: SessionService = SessionService(
        secureStorage: secureStorage,
        authRepository: authRepository
    )

    lazy var authService: AuthServiceProtocol = AuthServiceImpl(
        repository: authRepository,
        sessionService: sessionService
    )

    lazy var syncOrchestrator: SyncOrchestratorProtocol = SyncOrchestrator(
        messageRepository: messageRepository,
        contactRepository: contactRepository,
        networkMonitor: networkMonitor
    )

    lazy var pushManager: PushManagerProtocol = PushManager(
        grpcClient: grpcClient
    )

    lazy var mediaManager: MediaManagerProtocol = MediaManager(
        mediaEncryption: mediaEncryption
    )

    // MARK: - Calls

    lazy var webRTCClient: WebRTCClientProtocol = WebRTCClient()

    lazy var callManager: CallManagerProtocol = CallManager(
        webRTCClient: webRTCClient
    )

    // MARK: - Configuration

    let appConfiguration = AppConfiguration.current

    // MARK: - Init

    init() {
        // TODO: Perform any eager initialization here (e.g., start network monitor)
    }
}

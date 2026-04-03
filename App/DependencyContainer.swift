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

    // MARK: - Signal Protocol (E2EE)

    /// The unified Signal Protocol store backed by Keychain and local file persistence.
    /// Initialized with a placeholder user ID; updated after authentication via `configureSignalStore(userId:)`.
    lazy var signalStore: SanchrSignalStore = SanchrSignalStore(
        userId: sessionService.currentUserId ?? "pending",
        keychainService: keychainService
    )

    /// Key lifecycle manager: generates identity keys, signed pre-keys, one-time pre-keys,
    /// and synchronizes with the server's KeyService.
    lazy var signalKeyManager: SignalKeyManager = SignalKeyManager(
        store: signalStore,
        keyService: keyServiceClient
    )

    /// Session manager: X3DH session establishment, Double Ratchet encrypt/decrypt.
    lazy var signalSessionManager: SignalSessionManager = SignalSessionManager(
        store: signalStore,
        keyManager: signalKeyManager
    )

    /// gRPC client for the KeyService (pre-key uploads, bundle fetches, device queries).
    lazy var keyServiceClient: Vync_Keys_KeyServiceClientProtocol = Vync_Keys_KeyServiceClient(
        grpcClient: grpcClient
    )

    // MARK: - Crypto (Legacy Protocols Bridged to Signal)

    /// Exposes the `SignalKeyManager` as the `KeyManagerProtocol` for existing call sites.
    var keyManager: KeyManagerProtocol { signalKeyManager }

    /// Exposes the `SignalSessionManager` as the `SignalProtocolManagerProtocol` for existing call sites.
    var signalProtocol: SignalProtocolManagerProtocol { signalSessionManager }

    lazy var mediaEncryption: MediaEncryptionProtocol = MediaEncryptor()

    // MARK: - Repositories

    lazy var authRepository: AuthRepositoryProtocol = AuthRepositoryImpl(
        grpcClient: grpcClient,
        secureStorage: secureStorage
    )

    lazy var messageRepository: MessageRepositoryProtocol = MessageRepositoryImpl(
        grpcClient: grpcClient,
        localDatabase: localDatabase,
        signalProtocol: signalSessionManager
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

    // MARK: - Notifications

    /// gRPC client for the NotificationService (token registration, preference updates).
    lazy var notificationServiceClient: Vync_Notifications_NotificationServiceClientProtocol = Vync_Notifications_NotificationServiceClient(
        grpcClient: grpcClient
    )

    /// Manages APNs registration, token upload, foreground presentation, and notification actions.
    lazy var pushManager: PushManager = PushManager(
        notificationService: notificationServiceClient
    )

    // MARK: - Media

    lazy var mediaManager: MediaManagerProtocol = MediaManager(
        mediaEncryption: mediaEncryption
    )

    // MARK: - Calls

    /// gRPC client for the CallSignalingService.
    lazy var callSignalingService: Vync_Calling_CallSignalingServiceClientProtocol = Vync_Calling_CallSignalingServiceClient(
        grpcClient: grpcClient
    )

    /// WebRTC peer connection manager.
    lazy var webRTCClient: WebRTCClient = WebRTCClient()

    /// CallKit + signaling orchestrator for voice/video calls.
    lazy var callManager: CallManager = CallManager(
        webRTCClient: webRTCClient,
        callService: callSignalingService
    )

    /// Data source for call signaling gRPC operations.
    lazy var callDataSource: CallDataSource = CallDataSource(
        callService: callSignalingService
    )

    /// Use case: fetch and format call history.
    lazy var getCallHistoryUseCase: CallUseCases.GetCallHistory = CallUseCases.GetCallHistory(
        callDataSource: callDataSource
    )

    /// Use case: validate and start an outgoing call.
    lazy var startCallUseCase: CallUseCases.StartCall = CallUseCases.StartCall(
        callManager: callManager,
        networkMonitor: networkMonitor
    )

    /// Use case: fetch TURN credentials.
    lazy var getTurnCredentialsUseCase: CallUseCases.GetTurnCredentials = CallUseCases.GetTurnCredentials(
        callDataSource: callDataSource
    )

    // MARK: - Configuration

    let appConfiguration = AppConfiguration.current

    // MARK: - Init

    init() {
        // Eagerly start network monitoring if needed.
    }

    // MARK: - Post-Auth Signal Store Configuration

    /// Re-initializes the Signal Protocol store with the authenticated user's ID.
    /// Call this after successful login/registration when `SessionService.currentUserId` is set.
    func configureSignalStore(userId: String) {
        let store = SanchrSignalStore(userId: userId, keychainService: keychainService)
        self.signalStore = store
        self.signalKeyManager = SignalKeyManager(store: store, keyService: keyServiceClient)
        self.signalSessionManager = SignalSessionManager(store: store, keyManager: signalKeyManager)
        SanchrLogger.crypto.info("Signal Protocol store configured for user \(userId.prefix(8))...")
    }
}

import SwiftUI

/// Protocol-based dependency injection container.
/// All services are lazily initialized and shared across the app.
@Observable
final class DependencyContainer {

    // MARK: - Platform Services

    @ObservationIgnored lazy var keychainService: KeychainServiceProtocol = KeychainService()

    @ObservationIgnored lazy var secureStorage: SecureStorageProtocol = SecureStorage(
        keychain: keychainService
    )

    @ObservationIgnored lazy var networkMonitor: NetworkMonitorProtocol = NetworkMonitor()

    @ObservationIgnored lazy var authInterceptorFactory: AuthInterceptorFactory = {
        nonisolated(unsafe) weak var weakSelf = self
        return AuthInterceptorFactory(
            secureStorage: secureStorage,
            onUnauthenticated: {
                Task {
                    try? await weakSelf?.sessionService.forceRefreshToken()
                }
            }
        )
    }()

    @ObservationIgnored lazy var grpcClient: GRPCClientProtocol = SanchrGRPCClient(
        configuration: appConfiguration,
        authInterceptors: authInterceptorFactory
    )

    @ObservationIgnored lazy var localDatabase: LocalDatabaseProtocol = LocalDatabase()

    // MARK: - Signal Protocol (E2EE)

    /// The unified Signal Protocol store backed by Keychain and local file persistence.
    /// Initialized with a placeholder user ID; updated after authentication via `configureSignalStore(userId:)`.
    @ObservationIgnored lazy var signalStore: SanchrSignalStore = SanchrSignalStore(
        userId: sessionService.currentUserId ?? "pending",
        keychainService: keychainService
    )

    /// Key lifecycle manager: generates identity keys, signed pre-keys, one-time pre-keys,
    /// and synchronizes with the server's KeyService.
    @ObservationIgnored lazy var signalKeyManager: SignalKeyManager = SignalKeyManager(
        store: signalStore,
        keyService: grpcClient.keyService
    )

    /// Session manager: X3DH session establishment, Double Ratchet encrypt/decrypt.
    @ObservationIgnored lazy var signalSessionManager: SignalSessionManager = SignalSessionManager(
        store: signalStore,
        keyManager: signalKeyManager
    )

    // MARK: - Crypto (Legacy Protocols Bridged to Signal)

    /// Exposes the `SignalKeyManager` as the `KeyManagerProtocol` for existing call sites.
    var keyManager: KeyManagerProtocol { signalKeyManager }

    /// Exposes the `SignalSessionManager` as the `SignalProtocolManagerProtocol` for existing call sites.
    var signalProtocol: SignalProtocolManagerProtocol { signalSessionManager }

    @ObservationIgnored lazy var mediaEncryption: MediaEncryptionProtocol = MediaEncryptor()

    // MARK: - Repositories

    @ObservationIgnored lazy var authRepository: AuthRepositoryProtocol = AuthRepositoryImpl(
        grpcClient: grpcClient,
        secureStorage: secureStorage
    )

    @ObservationIgnored lazy var messageRepository: MessageRepositoryProtocol =
        MessageRepositoryImpl(
            grpcClient: grpcClient,
            localDatabase: localDatabase,
            signalProtocol: signalSessionManager
        )

    @ObservationIgnored lazy var contactRepository: ContactRepositoryProtocol =
        ContactRepositoryImpl(
            grpcClient: grpcClient,
            localDatabase: localDatabase
        )

    @ObservationIgnored lazy var vaultRepository: VaultRepositoryProtocol = VaultRepositoryImpl(
        grpcClient: grpcClient,
        localDatabase: localDatabase,
        mediaEncryption: mediaEncryption
    )

    // MARK: - Services

    @ObservationIgnored lazy var sessionService: SessionService = SessionService(
        secureStorage: secureStorage,
        authRepository: authRepository
    )

    @ObservationIgnored lazy var authService: AuthServiceProtocol = AuthServiceImpl(
        repository: authRepository,
        sessionService: sessionService
    )

    // MARK: - Security

    @ObservationIgnored lazy var appLockManager: AppLockManager = AppLockManager()

    // MARK: - Sync

    /// Tracks sync state across the app (last sync time, syncing indicator, errors).
    @ObservationIgnored lazy var syncState: SyncState = SyncState.load()

    /// Background sync coordinator using BGTaskScheduler.
    @ObservationIgnored lazy var syncOrchestrator: SyncOrchestrator = SyncOrchestrator(
        messageRepository: messageRepository,
        contactRepository: contactRepository,
        vaultRepository: vaultRepository,
        signalKeyManager: signalKeyManager,
        sessionService: sessionService,
        networkMonitor: networkMonitor,
        localDatabase: localDatabase,
        syncState: syncState
    )

    // MARK: - Notifications

    /// Manages APNs registration, token upload, foreground presentation, and notification actions.
    @ObservationIgnored lazy var pushManager: PushManager = PushManager(
        notificationService: grpcClient.notificationService
    )

    /// Convenience accessor for the notification gRPC client (used by NotificationsView).
    var notificationServiceClient: Vync_Notifications_NotificationServiceAsyncClientProtocol {
        grpcClient.notificationService
    }

    // MARK: - Media

    @ObservationIgnored lazy var mediaManager: MediaManagerProtocol = MediaManager(
        mediaEncryption: mediaEncryption
    )

    // MARK: - Chat Data

    @ObservationIgnored lazy var chatDataSource: ChatDataSource = ChatDataSource(
        grpcClient: grpcClient
    )

    // MARK: - Calls

    /// WebRTC peer connection manager.
    @ObservationIgnored lazy var webRTCClient: WebRTCClient = WebRTCClient()

    /// CallKit + signaling orchestrator for voice/video calls.
    @ObservationIgnored lazy var callManager: CallManager = CallManager(
        webRTCClient: webRTCClient,
        callService: grpcClient.callSignalingService
    )

    /// Data source for call signaling gRPC operations.
    @ObservationIgnored lazy var callDataSource: CallDataSource = CallDataSource(
        callService: grpcClient.callSignalingService
    )

    /// Use case: fetch and format call history.
    @ObservationIgnored lazy var getCallHistoryUseCase: CallUseCases.GetCallHistory =
        CallUseCases.GetCallHistory(
            callDataSource: callDataSource
        )

    /// Use case: validate and start an outgoing call.
    @ObservationIgnored lazy var startCallUseCase: CallUseCases.StartCall = CallUseCases.StartCall(
        callManager: callManager,
        networkMonitor: networkMonitor
    )

    /// Use case: fetch TURN credentials.
    @ObservationIgnored lazy var getTurnCredentialsUseCase: CallUseCases.GetTurnCredentials =
        CallUseCases.GetTurnCredentials(
            callDataSource: callDataSource
        )

    // MARK: - Configuration

    let appConfiguration = AppConfiguration.current

    // MARK: - Init

    init() {
        // Eagerly start network monitoring if needed.
    }

    // MARK: - gRPC Connection

    /// Establishes gRPC channels. Call this at app startup before making any service calls.
    func connectGRPC() async throws {
        try await grpcClient.connect()
        SanchrLogger.network.info("gRPC channels connected")
    }

    /// Gracefully shuts down all gRPC channels.
    func disconnectGRPC() async throws {
        try await grpcClient.disconnect()
    }

    // MARK: - Post-Auth Signal Store Configuration

    /// Re-initializes the Signal Protocol store with the authenticated user's ID.
    /// Call this after successful login/registration when `SessionService.currentUserId` is set.
    /// Migrates any keys stored under the "pending" placeholder to the real userId.
    func configureSignalStore(userId: String) {
        // Migrate keys from "pending" placeholder to real userId if needed
        migrateSignalKeysIfNeeded(from: "pending", to: userId)

        let store = SanchrSignalStore(userId: userId, keychainService: keychainService)
        self.signalStore = store
        self.signalKeyManager = SignalKeyManager(store: store, keyService: grpcClient.keyService)
        self.signalSessionManager = SignalSessionManager(store: store, keyManager: signalKeyManager)
        SanchrLogger.crypto.info("Signal Protocol store configured for user \(userId.prefix(8))...")
    }

    /// Migrates Signal Protocol Keychain entries and file-based stores from one userId to another.
    private func migrateSignalKeysIfNeeded(from oldUserId: String, to newUserId: String) {
        guard oldUserId != newUserId else { return }

        // Migrate Keychain entries (identity key pair and registration ID)
        let keychainMigrations = [
            ("io.sanchr.signal.identity_key_pair.\(oldUserId)", "io.sanchr.signal.identity_key_pair.\(newUserId)"),
            ("io.sanchr.signal.registration_id.\(oldUserId)", "io.sanchr.signal.registration_id.\(newUserId)"),
        ]

        for (oldKey, newKey) in keychainMigrations {
            // Only migrate if old key exists and new key doesn't
            if let data = try? keychainService.read(forKey: oldKey),
               (try? keychainService.read(forKey: newKey)) == nil {
                try? keychainService.save(data, forKey: newKey)
                try? keychainService.delete(forKey: oldKey)
                SanchrLogger.crypto.info("Migrated Keychain key from \(oldUserId.prefix(8)) to \(newUserId.prefix(8))")
            }
        }

        // Migrate file-based stores (sessions, pre-keys, trusted identities, sender keys)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldDir = base.appendingPathComponent("SignalStore/\(oldUserId)", isDirectory: true)
        let newDir = base.appendingPathComponent("SignalStore/\(newUserId)", isDirectory: true)

        if FileManager.default.fileExists(atPath: oldDir.path),
           !FileManager.default.fileExists(atPath: newDir.path) {
            do {
                try FileManager.default.moveItem(at: oldDir, to: newDir)
                SanchrLogger.crypto.info("Migrated Signal file store from \(oldUserId.prefix(8)) to \(newUserId.prefix(8))")
            } catch {
                SanchrLogger.crypto.error("Signal file store migration failed: \(error.localizedDescription)")
            }
        }
    }
}

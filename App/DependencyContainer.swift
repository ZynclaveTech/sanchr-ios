import SwiftUI
import SanchrShared

/// Protocol-based dependency injection container.
/// All services are lazily initialized and shared across the app.
@Observable
final class DependencyContainer: @unchecked Sendable {
    var localDataIssue: AppError?

    // MARK: - Platform Services

    @ObservationIgnored lazy var keychainService: KeychainServiceProtocol = KeychainService(
        accessGroup: AppGroup.keychainAccessGroup
    )

    @ObservationIgnored lazy var secureStorage: SecureStorageProtocol = SecureStorage(
        keychain: keychainService
    )

    @ObservationIgnored lazy var deviceSecretProvider: DeviceSecretProviderProtocol =
        DeviceSecretProvider(secureStorage: secureStorage)

    @ObservationIgnored lazy var localDatabaseKeyProvider: LocalDatabaseKeyProviderProtocol =
        LocalDatabaseKeyProvider(
            secureStorage: secureStorage,
            deviceSecrets: deviceSecretProvider
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

    @ObservationIgnored lazy var localDatabase: LocalDatabaseProtocol = makeLocalDatabase()

    /// See `LocalDatabaseOpener`. Built from the key provider only, so the
    /// open itself runs wherever `result()` is first called.
    @ObservationIgnored private lazy var localDatabaseOpener = LocalDatabaseOpener(
        open: { [keyProvider = localDatabaseKeyProvider] in
            do {
                return .success(try LocalDatabase(keyProvider: keyProvider))
            } catch let error as AppError {
                return .failure(error)
            } catch {
                return .failure(AppError.databaseError(reason: error.localizedDescription))
            }
        }
    )

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

    /// Sealed sender: certificate caching, delivery token pool, inner payload codec.
    @ObservationIgnored lazy var sealedSenderManager: SealedSenderManagerProtocol = SealedSenderManager(
        messagingService: grpcClient.messagingService,
        keychain: keychainService,
        // Every sealed payload carries the sender's Profile Key so distribution
        // is idempotent. Built over its own store rather than capturing the lazy
        // property, to avoid a reference cycle through the container.
        ownProfileKeyProvider: { [keychainService] in
            try? ProfileKeyStore(keychain: keychainService).ownProfileKey()
        },
        // Declares our true (userId, deviceId) inside every sealed payload so
        // receivers can store the session under the correct address instead of
        // a trial-decrypt guess.
        senderAddressProvider: { [weak self] in
            guard let self,
                let userId = self.sessionService.currentUserId, !userId.isEmpty
            else { return nil }
            let deviceId = Int32(self.sessionService.currentDeviceId ?? "") ?? 1
            return (userId: userId, deviceId: deviceId)
        }
    )

    // MARK: - Crypto (Legacy Protocols Bridged to Signal)

    /// Exposes the `SignalKeyManager` as the `KeyManagerProtocol` for existing call sites.
    var keyManager: KeyManagerProtocol { signalKeyManager }

    /// Exposes the `SignalSessionManager` as the `SignalProtocolManagerProtocol` for existing call sites.
    var signalProtocol: SignalProtocolManagerProtocol { signalSessionManager }

    @ObservationIgnored lazy var mediaEncryption: MediaEncryptionProtocol = MediaEncryptor()

    @ObservationIgnored lazy var photosSaver: PhotosSaving = PhotosSaver()

    @ObservationIgnored lazy var mediaChainState: MediaChainState = {
        do {
            let deviceSecret = try deviceSecretProvider.mediaAccessSecret()
            // Mirror the derived media-access secret into the shared keychain so
            // the share extension (which can't import Platform/DeviceSecretProvider
            // and can't re-derive it without the device master secret HKDF chain)
            // can rebuild an identical `MediaChainState` for cross-process sends.
            try? secureStorage.saveMediaAccessSecret(deviceSecret)
            return MediaChainState(deviceSecret: deviceSecret)
        } catch {
            // Fallback: Generate a temporary device secret if keychain is unavailable.
            // This allows the app to launch even if keychain is locked or inaccessible.
            SanchrLogger.security.error("Failed to retrieve media access secret from keychain: \(error)")
            let tempSecret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            return MediaChainState(deviceSecret: tempSecret)
        }
    }()

    @ObservationIgnored lazy var mediaUploadManager = MediaUploadManager(
        mediaEncryption: mediaEncryption,
        mediaKeyDerivation: mediaKeyDerivation,
        mediaChainState: mediaChainState,
        accessKeyStore: accessKeyStore,
        grpcClient: grpcClient
    )

    @ObservationIgnored lazy var mediaDownloadManager = MediaDownloadManager(
        mediaEncryption: mediaEncryption,
        accessKeyStore: accessKeyStore,
        grpcClient: grpcClient,
        vaultEKFScheduler: vaultEKFScheduler
    )

    /// Viewer-facing seam over `mediaDownloadManager` that adds a filename-
    /// preserving hard link path for `QLPreviewController`. Viewers bind
    /// to this protocol, not the concrete actor.
    @ObservationIgnored lazy var chatMediaResolver: ChatMediaResolving = ChatMediaResolverImpl(
        download: mediaDownloadManager
    )

    /// Container-scoped settings view model. Holds the global chat wallpaper
    /// id, theme, and other appearance preferences. Currently the canonical
    /// instance for `ChatAppearanceService` (Phase 2) which mirrors writes
    /// from `AppearanceView` and the per-chat `WallpaperThemeView` here.
    /// Existing per-screen `@State SettingsViewModel()` instances are
    /// migrated to read from this same instance in Phase 3.
    @MainActor @ObservationIgnored lazy var settingsViewModel: SettingsViewModel = SettingsViewModel()

    /// The single `SanchrTheme` instance shared with the SwiftUI environment
    /// at the SanchrApp root. Assigned by `SanchrApp.body.task` BEFORE any
    /// view reads `chatAppearance` so the resolver mirrors to the same
    /// instance the rest of the app sees through `@Environment(\.sanchrTheme)`.
    @MainActor var sharedTheme: SanchrTheme = SanchrTheme()

    /// Resolves the wallpaper + theme for any chat from the global
    /// settings + per-chat override store. Owned at container scope so
    /// the @Observable propagation works for every chat-detail / picker
    /// surface that reads from it.
    @MainActor @ObservationIgnored lazy var chatAppearance: ChatAppearanceService = ChatAppearanceService(
        localDatabase: localDatabase,
        theme: sharedTheme,
        settingsViewModel: settingsViewModel
    )

    /// Lock-protected mirror of the per-chat vault policy cache.
    /// Owned at container scope (not on the @MainActor service)
    /// because the nonisolated `messageRepository` lazy var reads it
    /// from the realtime decode path without crossing the main actor.
    /// `ChatVaultPolicyMirror` is `Sendable` so this is safe.
    @ObservationIgnored lazy var chatVaultPolicyMirror = ChatVaultPolicyMirror()

    /// Per-chat vault media policy resolver. Mirrors the
    /// chatAppearance pattern: @MainActor @Observable resolver +
    /// lock-protected sibling for the realtime decode path.
    @MainActor @ObservationIgnored lazy var chatVaultPolicy: ChatVaultPolicyService = ChatVaultPolicyService(
        localDatabase: localDatabase,
        mirror: chatVaultPolicyMirror
    )

    // MARK: - Cross-Process Send Pipeline (T16/T18)

    /// Cross-process file lock guarding Signal-protocol ratchet mutations on
    /// the send path. Owned by `MessageSender` so the main app and the share
    /// extension serialize their sends through the same on-disk sentinel.
    @ObservationIgnored lazy var fileCoordinatorLock = FileCoordinatorLock()

    /// Auth-retry adapter bridging the main-app `SessionService` to the
    /// SanchrShared `AuthRetrying` seam consumed by the encrypted send client.
    @ObservationIgnored lazy var authRetryingAdapter: AuthRetrying =
        SessionServiceAuthRetryingAdapter(sessionService: sessionService)

    /// Current-user adapter bridging `SessionService` to the SanchrShared
    /// `CurrentUserProviding` seam consumed by `MessageSender`.
    @ObservationIgnored lazy var currentUserProvider: CurrentUserProviding =
        SessionServiceCurrentUserAdapter(sessionService: sessionService)

    /// Extension-safe encrypted send client. Mirrors the legacy
    /// `ChatDataSource.sendEncryptedMessage` path but does not depend on any
    /// main-app types so it can be reused from the share extension.
    @ObservationIgnored lazy var encryptedMessageSendingClient: EncryptedMessageSendingClient =
        DefaultEncryptedMessageSendingClient(
            grpcClient: grpcClient,
            signalManager: signalProtocol,
            authRetrier: authRetryingAdapter
        )

    /// Sealed sender send client. Wraps plaintext in InnerPayload, Signal-encrypts
    /// per device, acquires a delivery token, and dispatches via unauthenticated RPC.
    @ObservationIgnored lazy var sealedMessageSendingClient: SealedMessageSendingClient = {
        // Parse the local device ID (stored as a String in the keychain).
        // Default to 1 if unreadable the filter is best-effort; a wrong
        // value simply means this device may receive a self-sync echo for
        // multi-device setups, which is harmless (dedup handles it).
        let deviceIdString = try? secureStorage.readDeviceId()
        let localDeviceId = Int32(deviceIdString ?? "") ?? 1
        return DefaultSealedMessageSendingClient(
            grpcClient: grpcClient,
            signalManager: signalProtocol,
            sealedSenderManager: sealedSenderManager,
            localDeviceId: localDeviceId
        )
    }()

    /// SOLE outgoing-message send pipeline. `ChatDetailViewModel` and the
    /// share-extension `ShareSendCoordinator` both call into this actor no
    /// other code path is allowed to write outgoing message rows.
    @ObservationIgnored lazy var messageSender: MessageSender = MessageSender(
        db: localDatabase,
        uploader: mediaUploadManager,
        encryptedSender: encryptedMessageSendingClient,
        sealedSender: sealedMessageSendingClient,
        coordinator: fileCoordinatorLock,
        currentUser: currentUserProvider,
        vaultPolicyResolver: MainAppVaultPolicyResolver(
            serviceProvider: { [unowned self] in self.chatVaultPolicy }
        ),
        networkMonitor: networkMonitor
    )

    // MARK: - Protocol Extensions (OPRF-PSI, Media Key Derivation, EKF)

    @ObservationIgnored lazy var oprfClient: OPRFClientProtocol = OPRFClient()

    @ObservationIgnored lazy var mediaKeyDerivation: MediaKeyDerivationProtocol = MediaKeyDerivation()

    @ObservationIgnored lazy var accessKeyStore: AccessKeyStoreProtocol =
        AccessKeyStore(localDatabase: localDatabase)

    @ObservationIgnored lazy var vaultEKFScheduler: VaultEKFScheduler =
        VaultEKFScheduler(accessKeyStore: accessKeyStore)

    /// Enforces disappearing-message deadlines on this device. Expiry is purely
    /// local — the server only reaps undelivered ciphertext.
    @ObservationIgnored lazy var disappearingSweeper: DisappearingMessageSweeper =
        DisappearingMessageSweeper(
            localDatabase: localDatabase,
            mediaDownloadManager: mediaDownloadManager
        )

    @ObservationIgnored lazy var discoveryRepository: DiscoveryRepositoryProtocol =
        DiscoveryRepository(grpcClient: grpcClient, oprfClient: oprfClient)

    @ObservationIgnored lazy var ekfClientService: EKFClientServiceProtocol =
        EKFClientService(accessKeyStore: accessKeyStore, keyManager: signalKeyManager)

    @ObservationIgnored lazy var ekfNotificationListener: EKFNotificationListener =
        EKFNotificationListener(ekfClientService: ekfClientService)

    // MARK: - Repositories

    @ObservationIgnored lazy var authRepository: AuthRepositoryProtocol = AuthRepositoryImpl(
        grpcClient: grpcClient,
        secureStorage: secureStorage
    )

    @ObservationIgnored lazy var messageRepository: MessageRepositoryProtocol = {
        nonisolated(unsafe) weak var weakSelf = self
        return MessageRepositoryImpl(
            grpcClient: grpcClient,
            localDatabase: localDatabase,
            signalProtocol: signalSessionManager,
            sealedSenderManager: sealedSenderManager,
            chatVaultPolicyMirror: chatVaultPolicyMirror,
            vaultRepository: vaultRepository,
            mediaDownloadManager: mediaDownloadManager,
            currentUserIdProvider: { weakSelf?.sessionService.currentUserId },
            privacySettings: privacySettings,
            profileKeyStore: profileKeyStore
        )
    }()

    @ObservationIgnored lazy var profileKeyStore: ProfileKeyStoreProtocol =
        ProfileKeyStore(keychain: keychainService)

    @ObservationIgnored lazy var profileCrypto: ProfileCryptoProtocol = ProfileCryptor()

    @ObservationIgnored lazy var contactRepository: ContactRepositoryProtocol =
        ContactRepositoryImpl(
            grpcClient: grpcClient,
            localDatabase: localDatabase,
            profileKeyStore: profileKeyStore,
            profileCrypto: profileCrypto
        )

    @ObservationIgnored lazy var vaultDataSource: VaultDataSource = VaultDataSource(
        grpcClient: grpcClient,
        accessKeyStore: accessKeyStore,
        mediaKeyDerivation: mediaKeyDerivation,
        deviceSecretProvider: deviceSecretProvider,
        mediaEncryption: mediaEncryption
    )

    @ObservationIgnored lazy var vaultRepository: VaultRepositoryProtocol = VaultRepositoryImpl(
        grpcClient: grpcClient,
        localDatabase: localDatabase,
        accessKeyStore: accessKeyStore,
        mediaEncryption: mediaEncryption,
        vaultDataSource: vaultDataSource,
        ekfScheduler: vaultEKFScheduler
    )

    /// Coordinator for the vault save/share flows. Owns the download
    /// → write-temp-file → cleanup pipeline used by Flow A (Save),
    /// Flow B1 (share to chat), Flow B2 (share outside Sanchr), and
    /// Flow C (chat attachment picker → vault item reshare).
    @ObservationIgnored lazy var vaultSharingCoordinator: VaultSharingCoordinating = VaultSharingCoordinator(
        vaultRepository: vaultRepository,
        messageSender: messageSender
    )

    // MARK: - Services

    @ObservationIgnored lazy var sessionService: SessionService = SessionService(
        secureStorage: secureStorage,
        authRepository: authRepository,
        privacySettings: privacySettings,
        cleanup: {
            nonisolated(unsafe) weak var weakSelf = self
            await weakSelf?.wipeLocalSessionArtifacts()
        },
        deepWipe: {
            nonisolated(unsafe) weak var weakSelf = self
            await weakSelf?.wipeAppGroupArtifacts()
        },
        onCredentialsChanged: { [headerCache = authInterceptorFactory.headerCache] in
            headerCache.invalidate()
        }
    )

    @ObservationIgnored lazy var authService: AuthServiceProtocol = AuthServiceImpl(
        repository: authRepository,
        sessionService: sessionService
    )

    // MARK: - Privacy

    let privacySettings = PrivacySettingsCache()

    // MARK: - Security

    @ObservationIgnored lazy var appLockManager: AppLockManager = AppLockManager()
    @MainActor @ObservationIgnored lazy var screenCaptureMonitor: ScreenCaptureMonitor = ScreenCaptureMonitor()

    @ObservationIgnored lazy var recoveryKeyManager: RecoveryKeyManagerProtocol = RecoveryKeyManager(
        secureStorage: secureStorage
    )

    @ObservationIgnored lazy var backupKeyDeriver: BackupKeyDeriverProtocol = SignalBackupKeyDeriver()

    @ObservationIgnored lazy var backupArchiveService: BackupArchiveServiceProtocol = BackupArchiveService(
        grpcClient: grpcClient,
        localDatabase: localDatabase,
        deviceSecretProvider: deviceSecretProvider,
        networkMonitor: networkMonitor
    )

    @ObservationIgnored lazy var backupCoordinator: BackupCoordinator = BackupCoordinator(
        backupService: backupArchiveService,
        recoveryKeyManager: recoveryKeyManager,
        backupKeyDeriver: backupKeyDeriver,
        currentUserIdProvider: { [weak self] in self?.sessionService.currentUserId },
        postRestore: { [weak self] in
            await self?.rebootstrapSignalStateAfterRestore()
        }
    )

    // MARK: - Sync

    /// Tracks sync state across the app (last sync time, syncing indicator, errors).
    @ObservationIgnored lazy var syncState: SyncState = SyncState.load()

    /// Background sync coordinator using BGTaskScheduler.
    @ObservationIgnored lazy var syncOrchestrator: SyncOrchestrator = SyncOrchestrator(
        messageRepository: messageRepository,
        contactRepository: contactRepository,
        signalKeyManager: signalKeyManager,
        sessionService: sessionService,
        networkMonitor: networkMonitor,
        realtimeService: realtimeService,
        backupCoordinator: backupCoordinator,
        syncState: syncState
    )

    // MARK: - Notifications

    /// Manages APNs registration, token upload, foreground presentation, and notification actions.
    @ObservationIgnored lazy var pushManager: PushManager = {
        nonisolated(unsafe) weak var weakSelf = self
        let manager = PushManager(notificationService: grpcClient.notificationService)
        manager.isAuthenticated = {
            weakSelf?.sessionService.isAuthenticated ?? false
        }
        manager.isConversationMuted = { conversationId in
            guard let container = weakSelf else { return false }
            return (try? await container.localDatabase.fetchConversation(id: conversationId)?.isMuted) ?? false
        }
        manager.silentPushHandler = { payload in
            guard let container = weakSelf else { return .noData }

            let syncedCount = await container.realtimeService.syncNow()
            let conversations = (try? await container.messageRepository.fetchConversations()) ?? []
            let unreadCount = conversations.reduce(0) { $0 + $1.unreadCount }
            let effectiveBadge = payload.badge ?? unreadCount
            await SanchrNotificationService.updateBadgeCount(effectiveBadge)

            return syncedCount > 0 ? .newData : (payload.badge == nil ? .noData : .newData)
        }
        manager.incomingVoIPCallHandler = { callId, callerId, callerDevice, callType, encryptedSdpPayload in
            guard let container = weakSelf else { return }
            // handleVoIPPushIncomingCall must be called synchronously in the PushKit callback.
            // Since this closure is invoked directly from pushRegistry(_:didReceiveIncomingPushWith:),
            // we are already on the main queue (PKPushRegistry was set up on .main).
            container.callManager.handleVoIPPushIncomingCall(
                callId: callId,
                callerId: callerId,
                callerDevice: callerDevice,
                callType: callType,
                encryptedSdpPayload: encryptedSdpPayload
            )
            // Open the MessageStream so the queued CallOfferEvent (with encrypted SDP) is
            // delivered from Redis and handleIncomingCallOffer can set pendingSdpOffer.
            // start() is idempotent if the stream is already running this is a no-op.
            container.realtimeService.start()
        }
        return manager
    }()

    /// Convenience accessor for the notification gRPC client (used by NotificationsView).
    var notificationServiceClient: Sanchr_Notifications_NotificationServiceAsyncClientProtocol {
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
    @ObservationIgnored lazy var callManager: CallManager = {
        let localDatabase = self.localDatabase
        return CallManager(
            webRTCClient: self.webRTCClient,
            callService: self.grpcClient.callSignalingService,
            signalManager: self.signalProtocol,
            tokenRefresher: { [weak self] in
                _ = try await self?.sessionService.refreshTokenIfExpiringSoon()
            },
            peerProfileResolver: { userId in
                await Self.resolveCallPeerProfile(
                    userId: userId,
                    localDatabase: localDatabase
                )
            },
            localDeviceIdProvider: { [weak self] in
                Int32(self?.sessionService.currentDeviceId ?? "") ?? 1
            },
            isVideoCallEnabled: AppConfiguration.current.isVideoCallEnabled
        )
    }()

    @ObservationIgnored lazy var realtimeService: RealtimeService = RealtimeService(
        messageRepository: messageRepository,
        signalKeyManager: signalKeyManager,
        sessionService: sessionService,
        callManager: callManager,
        privacySettings: privacySettings,
        networkMonitor: networkMonitor
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
    @ObservationIgnored lazy var startCallUseCase: CallUseCases.StartCall = {
        nonisolated(unsafe) weak var weakSelf = self
        return CallUseCases.StartCall(
            callManager: callManager,
            networkMonitor: networkMonitor,
            tokenRefresher: {
                _ = try await weakSelf?.sessionService.forceRefreshToken()
            }
        )
    }()

    /// Use case: fetch TURN credentials.
    @ObservationIgnored lazy var getTurnCredentialsUseCase: CallUseCases.GetTurnCredentials =
        CallUseCases.GetTurnCredentials(
            callDataSource: callDataSource
        )

    // MARK: - Configuration

    let appConfiguration = AppConfiguration.current

    // MARK: - Init

    /// Absence of this key means the app container is new, so any surviving
    /// Keychain items belong to a previous installation.
    private static let installMarkerKey = "sanchr.install.marker"

    /// Keychain items outlive app deletion on iOS — Apple's documented behaviour,
    /// not a bug — while the app container (UserDefaults, the database, files) is
    /// removed. A reinstall therefore starts with credentials, device secrets and
    /// Signal state belonging to an installation that no longer exists.
    ///
    /// This has to run before anything else in this initialiser. The database key
    /// provider, the Signal store and the session are all Keychain consumers, and
    /// once any of them has read a stale value the damage is done: the database
    /// gets created under a master secret that is about to be discarded, and the
    /// session is restored for an account the server may never have heard of.
    ///
    /// UserDefaults is wiped on delete, so its emptiness is the signal that this
    /// container is new.
    /// What the launch-time Keychain check should do.
    enum FreshInstallAction: Equatable {
        /// The marker is present: an ordinary launch.
        case nothing
        /// No marker, but a database from before the marker existed: an
        /// upgrade, not a reinstall. Seed the marker and keep everything.
        case seedMarkerOnly
        /// No marker and no data: a reinstall over stale Keychain items.
        case purge
    }

    /// The marker was introduced after users already existed. On their
    /// first launch of a build that has it, the marker is absent for the
    /// same reason it is absent on a reinstall, and purging would throw
    /// away their database key and sign them out. The local database is
    /// the tie-breaker: a reinstall cannot have one.
    static func freshInstallAction(markerPresent: Bool, databaseExists: Bool) -> FreshInstallAction {
        if markerPresent { return .nothing }
        return databaseExists ? .seedMarkerOnly : .purge
    }

    private static func purgeKeychainIfFreshInstall() {
        let defaults = UserDefaults.standard
        let databaseExists = FileManager.default.fileExists(atPath: AppGroup.databaseURL.path)
            || FileManager.default.fileExists(atPath: AppGroupMigration.legacyDatabaseURL.path)
        switch freshInstallAction(
            markerPresent: defaults.object(forKey: installMarkerKey) != nil,
            databaseExists: databaseExists
        ) {
        case .nothing:
            return
        case .seedMarkerOnly:
            defaults.set(true, forKey: installMarkerKey)
            SanchrLogger.auth.info(
                "install marker seeded for an existing install — Keychain left intact")
            return
        case .purge:
            break
        }

        // Written first: if the purge throws, the next launch must not retry it
        // forever and wipe a session established since.
        defaults.set(true, forKey: installMarkerKey)

        // Built directly rather than through the lazy `secureStorage` property:
        // this runs before `self` is fully initialised, so the stored properties
        // are not reachable yet. Same access group, so it addresses the same
        // items.
        let storage = SecureStorage(
            keychain: KeychainService(accessGroup: AppGroup.keychainAccessGroup))

        do {
            try storage.purgeAllKeychainItems()
            // The Profile Key went with it, so the key every contact holds no
            // longer opens our profile. Forget who we have told, so the new key
            // reaches all of them.
            ProfileKeyStore(keychain: KeychainService(accessGroup: AppGroup.keychainAccessGroup))
                .clearOwnProfileKeyDeliveryMarkers()
            SanchrLogger.auth.info(
                "fresh install — purged Keychain items left by a previous installation")
        } catch {
            SanchrLogger.auth.error(
                "fresh install — Keychain purge failed: \(error.localizedDescription)")
        }
    }

    init() {
        Self.purgeKeychainIfFreshInstall()

        // Start opening the database now, off the main thread, so the first
        // view to need it does not pay for key derivation and migrations on
        // its own render. The test host builds a container without ever
        // touching the database; keep it that way.
        if !ProcessInfo.processInfo.sanchrIsRunningUnitTests {
            localDatabaseOpener.prewarm()
        }

        // Eagerly start network monitoring if needed.

        // Vault share temp-file sweep. Runs detached at utility priority
        // so it doesn't block startup any orphans from a crashed share
        // are cleaned up before the user touches the vault view. The
        // entire vault-share/ directory is removed unconditionally: no
        // valid share spans an app restart, so there's nothing to
        // preserve.
        Task.detached(priority: .utility) {
            await VaultSharingCoordinator.sweepOrphanedTempFiles()
        }
    }

    private func makeLocalDatabase() -> LocalDatabaseProtocol {
        switch localDatabaseOpener.result() {
        case .success(let database):
            localDataIssue = nil
            return database
        case .failure(let error):
            localDataIssue = error
            return UnavailableLocalDatabase(error: error)
        }
    }

    static func resolveCallPeerProfile(
        userId: String,
        localDatabase: LocalDatabaseProtocol
    ) async -> CallPeerProfile? {
        if let contacts = try? await localDatabase.fetchContacts(),
           let contact = contacts.first(where: { $0.id == userId }),
           let profile = callPeerProfile(for: contact, userId: userId)
        {
            return profile
        }

        guard let conversations = try? await localDatabase.fetchConversations() else {
            return nil
        }

        for conversation in conversations {
            if let participant = conversation.participants.first(where: { $0.id == userId }),
               let profile = callPeerProfile(for: participant, userId: userId)
            {
                return profile
            }
        }

        return nil
    }

    private static func callPeerProfile(for user: User, userId: String) -> CallPeerProfile? {
        let displayName = callDisplayName(for: user, userId: userId)
        guard displayName != nil || user.avatarURL != nil else {
            return nil
        }
        return CallPeerProfile(displayName: displayName, avatarURL: user.avatarURL)
    }

    private static func callDisplayName(for user: User, userId: String) -> String? {
        let displayName = user.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        // The server placeholder is not a real name — it must fall through to the
        // phone number, exactly as the conversation list does, rather than being
        // shown on the call screen (or, once filtered, collapsing to "Unknown").
        if !displayName.isEmpty,
            displayName != userId,
            displayName != User.serverPlaceholderDisplayName,
            UUID(uuidString: displayName) == nil
        {
            return displayName
        }

        let phoneNumber = user.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !phoneNumber.isEmpty, phoneNumber != userId {
            return phoneNumber
        }

        return nil
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

    func resetLocalDataAfterBootstrapFailure() async {
        await resetLocalSecrets()
    }

    func resetLocalSecretsForDebug() async {
        await resetLocalSecrets()
    }

    private func resetLocalSecrets() async {
        realtimeService.stop()
        callManager.resetState()
        try? localDatabaseKeyProvider.resetDatabaseSecrets()
        try? LocalDatabase.destroyDatabaseFiles()
        // The destroyed local DB is gone but the session's sync high-water
        // mark still points at the last message we had. Reset it so the next
        // syncPendingMessages() pulls the full server-side history instead
        // of only messages newer than the stale mark.
        await sessionService.resetMessageSyncHighWaterMark()
        localDatabaseOpener.reset()
        localDatabase = makeLocalDatabase()
    }

    // MARK: - Post-Auth Signal Store Configuration

    /// Re-initializes the Signal Protocol store with the authenticated user's ID.
    /// Call this after successful login/registration when `SessionService.currentUserId` is set.
    /// Migrates any keys stored under the "pending" placeholder to the real userId.
    func configureSignalStore(userId: String) {
        realtimeService.stop()
        syncOrchestrator.stopSync()

        // Migrate keys from "pending" placeholder to real userId if needed
        migrateSignalKeysIfNeeded(from: "pending", to: userId)

        let store = SanchrSignalStore(userId: userId, keychainService: keychainService)
        self.signalStore = store
        self.signalKeyManager = SignalKeyManager(store: store, keyService: grpcClient.keyService)
        self.signalSessionManager = SignalSessionManager(store: store, keyManager: signalKeyManager)
        self.messageRepository = MessageRepositoryImpl(
            grpcClient: grpcClient,
            localDatabase: localDatabase,
            signalProtocol: signalSessionManager,
            sealedSenderManager: sealedSenderManager,
            chatVaultPolicyMirror: chatVaultPolicyMirror,
            vaultRepository: vaultRepository,
            mediaDownloadManager: mediaDownloadManager,
            currentUserIdProvider: { [weak self] in self?.sessionService.currentUserId },
            privacySettings: privacySettings,
            profileKeyStore: profileKeyStore
        )
        // Rebuild the cross-process send pipeline so it captures the freshly
        // installed `signalSessionManager`. The `MessageSender` actor itself
        // is rebuilt for the same reason its `encryptedSender` dependency
        // is held as a stored property and would otherwise reference the old
        // signal manager indefinitely.
        self.encryptedMessageSendingClient = DefaultEncryptedMessageSendingClient(
            grpcClient: grpcClient,
            signalManager: signalSessionManager,
            authRetrier: authRetryingAdapter
        )
        let deviceIdStr = try? secureStorage.readDeviceId()
        self.sealedMessageSendingClient = DefaultSealedMessageSendingClient(
            grpcClient: grpcClient,
            signalManager: signalSessionManager,
            sealedSenderManager: sealedSenderManager,
            localDeviceId: Int32(deviceIdStr ?? "") ?? 1
        )
        self.messageSender = MessageSender(
            db: localDatabase,
            uploader: mediaUploadManager,
            encryptedSender: encryptedMessageSendingClient,
            sealedSender: sealedMessageSendingClient,
            coordinator: fileCoordinatorLock,
            currentUser: currentUserProvider,
            vaultPolicyResolver: MainAppVaultPolicyResolver(
                serviceProvider: { [unowned self] in self.chatVaultPolicy }
            ),
            networkMonitor: networkMonitor
        )
        self.realtimeService = RealtimeService(
            messageRepository: messageRepository,
            signalKeyManager: signalKeyManager,
            sessionService: sessionService,
            callManager: callManager,
            privacySettings: privacySettings,
            networkMonitor: networkMonitor
        )
        self.syncOrchestrator = SyncOrchestrator(
            messageRepository: messageRepository,
            contactRepository: contactRepository,
            signalKeyManager: signalKeyManager,
            sessionService: sessionService,
            networkMonitor: networkMonitor,
            realtimeService: realtimeService,
            backupCoordinator: backupCoordinator,
            syncState: syncState
        )
        self.syncOrchestrator.registerHandlers()
        SanchrLogger.crypto.info("Signal Protocol store configured for user \(userId.prefix(8))...")
        SanchrLogger.crypto.info("Rebuilt crypto-bound repositories and realtime services for authenticated user")
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

    private func wipeLocalSessionArtifacts() async {
        realtimeService.stop()
        await ekfNotificationListener.stop()
        callManager.resetState()
        try? secureStorage.deleteSignalStateKeys()
        try? await localDatabase.purgeAllData()
        try? await mediaManager.clearCache()
        QuickLookDisplayLinks.sweep()
        removeSignalStoreDirectory()
        pushManager.resetUploadState()
        SanchrNotificationService.clearAllNotifications()
        syncState.lastSyncTimestamp = nil
        syncState.pendingMessageCount = 0
        syncState.syncError = nil
    }

    /// Best-effort wipe of every App Group artifact. Used when the user
    /// permanently deletes their account. Each step swallows errors so one
    /// failure cannot strand the user in a partially-deleted state.
    private func wipeAppGroupArtifacts() async {
        let fm = FileManager.default

        // Standard defaults hold the push token, restore-offer flags and
        // delivery markers; a deleted account leaves none of them behind.
        // (The install marker goes too, which is right: the next launch is a
        // fresh install over a Keychain that is already empty.)
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        // The Profile Key is iCloud-synchronized so it survives reinstalls;
        // a deleted account must not leave it for the next sign-in.
        try? profileKeyStore.deleteOwnProfileKey()
        profileKeyStore.clearOwnProfileKeyDeliveryMarkers()

        // Database file and any -wal/-shm sidecars.
        let dbURL = AppGroup.databaseURL
        for url in [dbURL, dbURL.appendingPathExtension("wal"), dbURL.appendingPathExtension("shm")] {
            if fm.fileExists(atPath: url.path) {
                do { try fm.removeItem(at: url) }
                catch { SanchrLogger.app.error("deleteAccount: failed to remove \(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }

        // Sender coordination lock file.
        let lockURL = AppGroup.senderLockURL
        if fm.fileExists(atPath: lockURL.path) {
            do { try fm.removeItem(at: lockURL) }
            catch { SanchrLogger.app.error("deleteAccount: failed to remove sender lock: \(error.localizedDescription)") }
        }

        // Media cache directory wipe contents but leave the dir so future
        // launches don't need to recreate it.
        let mediaDir = AppGroup.mediaCacheURL
        if let entries = try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil) {
            for entry in entries {
                do { try fm.removeItem(at: entry) }
                catch { SanchrLogger.app.error("deleteAccount: failed to remove media cache entry \(entry.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        // Hard links to that media, handed to QuickLook.
        QuickLookDisplayLinks.sweep()

        // Shared UserDefaults suite.
        AppGroup.userDefaults.removePersistentDomain(forName: AppGroup.identifier)
        AppGroup.userDefaults.synchronize()

        SanchrLogger.app.warning("deleteAccount: App Group artifacts wiped")
    }

    private func removeSignalStoreDirectory() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let signalStoreDir = base.appendingPathComponent("SignalStore", isDirectory: true)
        if FileManager.default.fileExists(atPath: signalStoreDir.path) {
            try? FileManager.default.removeItem(at: signalStoreDir)
        }
    }

    private func rebootstrapSignalStateAfterRestore() async {
        realtimeService.stop()
        callManager.resetState()
        try? secureStorage.deleteSignalStateKeys()
        removeSignalStoreDirectory()

        guard let userId = sessionService.currentUserId else { return }

        configureSignalStore(userId: userId)
        do {
            _ = try signalKeyManager.generateIdentityIfNeeded()
            try await signalKeyManager.uploadInitialKeyBundle()
        } catch {
            SanchrLogger.crypto.error(
                "Signal state rebootstrap after restore failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Vault EKF Scheduler Lifecycle

    /// Called from the SanchrApp scene-phase handler on foreground.
    /// Starts the vault EKF scheduler and fires an immediate purge tick.
    /// The tick provides best-effort cleanup for apps that only foreground
    /// briefly (<15 min, shorter than the scheduler's interval). Idempotent.
    func startVaultEKFScheduler() async {
        await vaultEKFScheduler.start()
        try? await vaultEKFScheduler.tick()
    }

    /// Called from the SanchrApp scene-phase handler on background.
    /// Stops the vault EKF scheduler. Idempotent.
    func stopVaultEKFScheduler() async {
        await vaultEKFScheduler.stop()
    }
}

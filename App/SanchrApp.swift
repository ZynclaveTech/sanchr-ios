import Combine
import SwiftUI
import UserNotifications
import SanchrShared

private struct SendableNotificationPayload: @unchecked Sendable {
    let userInfo: [AnyHashable: Any]
}

extension ProcessInfo {
    var sanchrIsRunningUnitTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}

/// Main entry point for the Sanchr encrypted messaging application.
/// Configures the app environment, dependency injection, APNs delegate,
/// background sync registration, and root scene.
@main
struct SanchrApp: App {
    @UIApplicationDelegateAdaptor(SanchrAppDelegate.self) private var appDelegate
    @State private var container = DependencyContainer()
    @State private var appRouter = AppRouter()
    @State private var sanchrTheme = SanchrTheme()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sanchr.themeMode") private var storedThemeMode = SanchrTheme.Mode.light.rawValue
    @State private var cancellables = Set<AnyCancellable>()
    /// Owned at App level so it survives background/foreground cycles
    /// and SwiftUI view-tree reconciliation without resetting to true.
    @State private var showSplash = true
    /// Whether the user has authenticated at the app lock gate (if enabled).
    /// This gates the entire app to prevent unauthorized access.
    @State private var hasAuthenticatedAtGate = false

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.sanchrIsRunningUnitTests {
                Color.clear
            } else if container.appLockManager.biometricLockEnabled && !hasAuthenticatedAtGate {
                // App lock is enabled and user hasn't authenticated yet —
                // Block access to the entire app until authentication succeeds.
                AppLockGateView(isAuthenticated: $hasAuthenticatedAtGate)
            } else {
                RootView(showSplash: $showSplash)
                    .environment(container)
                    .environment(appRouter)
                    .environment(container.syncState)
                    .environment(\.sanchrTheme, sanchrTheme)
                    // Drive preferredColorScheme directly from @AppStorage
                    // because EnvironmentKey-based injections do NOT track
                    // @Observable mutations on a class only identity
                    // changes to the environment value re-trigger the
                    // modifier. AppearanceView writes to the same AppStorage
                    // key on every theme pick, so this bridge actually fires.
                    .preferredColorScheme(SanchrTheme.Mode(rawValue: storedThemeMode)?.colorScheme)
                    .onAppear {
                        configureAppearance()
                        if container.localDataIssue == nil {
                            configureBackgroundSync()
                        }
                        // Record first-launch date for security nudge timing (idempotent).
                        SecurityNudge.recordFirstLaunchIfNeeded()
                    }
                    .task {
                        container.sharedTheme = sanchrTheme
                        if let saved = SanchrTheme.Mode(rawValue: storedThemeMode) {
                            sanchrTheme.mode = saved
                        }
                        do {
                            try await container.connectGRPC()
                        } catch {
                            SanchrLogger.network.error("Failed to connect gRPC channels: \(error.localizedDescription)")
                        }
                        // One-time purge of AccessK entries derived under old HKDF params.
                        await container.accessKeyStore.migrateHKDFv2IfNeeded()
                        // Client-side expiry of AccessK entries. The listener
                        // existed but nothing ever started it, so expired keys
                        // were never purged on this device.
                        await container.ekfNotificationListener.purgeExpiredKeys()
                        await container.ekfNotificationListener.startPeriodicPurge()
                        // Drop disappearing-message timers left in plaintext
                        // UserDefaults by earlier builds; they live in the
                        // encrypted conversation row now.
                        let purged = DisappearingTimerLegacyCleanup.purge()
                        if purged > 0 {
                            SanchrLogger.chat.info(
                                "Removed \(purged) legacy plaintext disappearing timer(s)")
                        }
                        // Clear anything that expired while the app was closed before
                        // the first transcript can render, then keep sweeping.
                        let sweeper = container.disappearingSweeper
                        await sweeper.sweep()
                        await sweeper.start()
                        // Wire PushManager after gRPC is connected (it needs notificationService)
                        await MainActor.run {
                            configurePushManager()
                        }
                        // Flush queued messages whenever connectivity is restored.
                        let messageSender = container.messageSender
                        container.networkMonitor.connectivityPublisher
                            .dropFirst()
                            .removeDuplicates()
                            .filter { $0 == true }
                            .sink { _ in
                                Task {
                                    await messageSender.retrySendingMessages()
                                }
                            }
                            .store(in: &cancellables)
                    }
                    .onChange(of: scenePhase) { oldPhase, newPhase in
                        handleScenePhaseChange(from: oldPhase, to: newPhase)
                    }
            }
        }
    }

    // MARK: - Setup

    /// Applies global appearance overrides for UIKit components embedded in SwiftUI.
    private func configureAppearance() {
        // TODO: Configure UINavigationBar, UITabBar default appearances
        // to match SanchrTheme tokens.
    }

    /// Wire the PushManager as the UNUserNotificationCenter delegate
    /// and share it with the AppDelegate for token forwarding.
    ///
    /// Also registers `onSilentWakeup` so that sealed-sender background pushes
    /// (which carry no custom payload) trigger a gRPC sync and schedule a
    /// local `UNNotificationRequest` to surface new messages to the user.
    private func configurePushManager() {
        let pushManager = container.pushManager
        UNUserNotificationCenter.current().delegate = pushManager
        appDelegate.pushManager = pushManager

        // Capture the realtime service as a let so the Sendable closure can
        // reference it without retaining `self` (which is a SwiftUI struct).
        let realtimeService = container.realtimeService
        let messageRepository = container.messageRepository
        let messageSender = container.messageSender
        let callManager = container.callManager
        pushManager.onInlineReply = { @Sendable conversationId, text in
            do {
                _ = try await messageSender.sendText(text, to: conversationId)
            } catch {
                SanchrLogger.push.error("Inline reply failed: \(error.localizedDescription)")
            }
        }
        pushManager.onDeclineCall = { @Sendable callId in
            await callManager.declineCall(fromNotificationFor: callId)
        }
        pushManager.onSilentWakeup = { @Sendable in
            let syncResult = await realtimeService.syncNowResult()
            guard syncResult.appliedCount > 0 else { return .noData }

            let conversations = (try? await messageRepository.fetchConversations()) ?? []
            let mutedConversationIds = Set(
                conversations.lazy.filter(\.isMuted).map(\.id)
            )
            let unmutedCount = syncResult.appliedCountsByConversation.reduce(into: 0) {
                total, entry in
                guard !mutedConversationIds.contains(entry.key) else { return }
                total += entry.value
            }
            guard unmutedCount > 0 else {
                SanchrLogger.push.info(
                    "Silent push synced only muted conversation(s); skipping local notification")
                return .newData
            }

            // Schedule a local notification to alert the user. Message content
            // is E2EE so we show a generic placeholder — a future
            // NotificationServiceExtension can decrypt and enrich this.
            let content = UNMutableNotificationContent()
            content.title = "Sanchr"
            content.body = unmutedCount == 1 ? "New message" : "\(unmutedCount) new messages"
            content.sound = .default
            content.categoryIdentifier = SanchrNotificationCategory.message

            let request = UNNotificationRequest(
                identifier: "sanchr.bg.message-\(UUID().uuidString)",
                content: content,
                trigger: nil  // deliver immediately
            )
            try? await UNUserNotificationCenter.current().add(request)
            SanchrLogger.push.info(
                "Scheduled local notification for \(unmutedCount) unmuted new message(s) from silent push")
            return .newData
        }

        // Register with PushKit for VoIP pushes. The incomingVoIPCallHandler closure
        // is already wired in DependencyContainer.pushManager lazy var.
        pushManager.setupVoIPRegistration()

        SanchrLogger.push.info("PushManager wired as UNUserNotificationCenter delegate")
    }

    /// Wire up the background sync orchestrator with live handlers.
    private func configureBackgroundSync() {
        container.syncOrchestrator.registerHandlers()
        SanchrLogger.sync.info("Background sync orchestrator configured with live handlers")
    }

    // MARK: - Scene Phase Handling

    /// Responds to scene phase transitions to schedule/trigger syncs.
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        let lockManager = container.appLockManager

        switch newPhase {
        case .background:
            // Schedule background tasks when the app goes to background.
            let orchestrator = container.syncOrchestrator
            orchestrator.scheduleBackgroundSync()
            orchestrator.scheduleAppRefresh()
            lockManager.appDidEnterBackground()

            // Reset app lock gate authentication — when app returns to foreground,
            // the gate will require re-authentication if biometric lock is enabled.
            hasAuthenticatedAtGate = false

            container.realtimeService.enterBackground()
            SanchrLogger.sync.info("App entered background, scheduled background tasks")

            // Stop the vault EKF scheduler. A best-effort purge will run on
            // next foreground.
            Task {
                await container.stopVaultEKFScheduler()
                // Sweep once more on the way out so expired content is not sitting
                // in the database while the app is suspended.
                await container.disappearingSweeper.sweep()
                await container.disappearingSweeper.stop()
            }

        case .active:
            // Check app lock
            lockManager.appDidBecomeActive()
            container.realtimeService.enterForeground()
            Task { await container.ekfNotificationListener.purgeExpiredKeys() }
            // Rotate push token every 7 days to limit long-term token tracking.
            container.pushManager.rotateTokenIfNeeded()

            // Trigger a foreground sync if needed (>5 min since last sync).
            let syncState = container.syncState
            if syncState.needsSync && container.sessionService.isAuthenticated {
                SanchrLogger.sync.info("App became active, triggering foreground sync")
                Task {
                    await container.syncOrchestrator.startSync()
                }
            }

            // Flush any messages queued while the app was backgrounded.
            Task {
                await container.messageSender.retrySendingMessages()
            }

            // Enforce disappearing-message deadlines that elapsed while the app was
            // away, before any transcript is drawn, then resume periodic sweeping.
            Task {
                let sweeper = container.disappearingSweeper
                await sweeper.sweep()
                await sweeper.start()
            }

            // Start the vault EKF scheduler (idempotent).
            Task {
                await container.startVaultEKFScheduler()
            }

        case .inactive:
            break

        @unknown default:
            break
        }
    }
}

// MARK: - AppDelegate

/// UIKit app delegate required for APNs token callbacks, silent push handling,
/// and BGTaskScheduler registration.
/// SwiftUI's `@UIApplicationDelegateAdaptor` bridges these callbacks into the SwiftUI lifecycle.
final class SanchrAppDelegate: NSObject, UIApplicationDelegate {

    /// Injected by SanchrApp after the container is initialized.
    var pushManager: PushManager?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        SanchrLogger.app.info("Application didFinishLaunching")

        // Run the App Group database migration BEFORE anything touches the
        // local database. `DependencyContainer.localDatabase` is lazy and
        // the first access opens the SQLCipher file at the App Group path;
        // if legacy data still lives at the old Application Support path we
        // have to copy it over first or the user will see an empty install.
        // `runIfNeeded()` is idempotent, non-throwing, and a no-op on clean
        // installs, so it is safe to call unconditionally on every launch.
        if !ProcessInfo.processInfo.sanchrIsRunningUnitTests {
            AppGroupMigration.runIfNeeded()
        }

        // Register background task identifiers early (before app finishes launching).
        if !ProcessInfo.processInfo.sanchrIsRunningUnitTests {
            SyncOrchestrator.registerBackgroundTasks()
        }

        // Check if launched from a notification
        if let remoteNotification = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            let notification = SendableNotificationPayload(userInfo: remoteNotification)
            Task { @Sendable in
                await self.pushManager?.handleNotification(userInfo: notification.userInfo)
            }
        }

        return true
    }

    /// Called when APNs successfully registers and delivers the device token.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        pushManager?.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    /// Called when APNs registration fails.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        SanchrLogger.push.error("APNs registration failed: \(error.localizedDescription)")
    }

    /// Handle silent/background push notifications (content-available: 1).
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let pushManager else {
            completionHandler(.noData)
            return
        }

        let info = SendableNotificationPayload(userInfo: userInfo)
        Task { @Sendable in
            let result = await pushManager.handleSilentPush(userInfo: info.userInfo)
            completionHandler(result)
        }
    }
}

// MARK: - Root View

/// Presents either the authentication flow or the main tab interface
/// based on the current session state.
struct RootView: View {
    @Binding var showSplash: Bool
    @Environment(DependencyContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @AppStorage("sanchr.activeOnboardingFlow") private var activeOnboardingFlow = false
    @State private var sessionReady = false
    @State private var restoreSources: BackupRestoreSources?
    @State private var restoreOfferChecked = false

    /// Process-lifetime flag — stored in the type's memory, not in SwiftUI's
    /// state system. SwiftUI cannot reset this on view reconciliation or scene
    /// lifecycle events. Once the splash has played once after a cold launch,
    /// this is permanently `true` for the life of the process.
    @MainActor private static var splashHasPlayed = false

    private var hasCompletedProfileBasics: Bool {
        // A name is only meaningful if we still hold the Profile Key it was
        // encrypted under. The key lives solely in the Keychain, and
        // ownProfileKey() mints a fresh one whenever that is empty — so after a
        // reinstall, or any restore that does not carry the Keychain across, we
        // have a *different* key while the server still holds the profile
        // ciphertext produced by the old one.
        //
        // Nothing can recover the name at that point: the key that opened it is
        // gone, and no contact can read the profile either, because the key we
        // are now handing them does not fit. Carrying on would leave the account
        // permanently nameless to everyone.
        //
        // Treating it as incomplete sends the user back through name entry, and
        // saving re-encrypts and re-uploads under the current key, which is the
        // only way out.
        guard container.profileKeyStore.hasOwnProfileKey() else { return false }

        let name = container.sessionService.currentDisplayName ?? ""
        return !name.isEmpty && name != User.serverPlaceholderDisplayName
    }

    /// Whether the user still needs to complete onboarding.
    private var needsOnboarding: Bool {
        activeOnboardingFlow || !hasCompletedProfileBasics
    }

    var body: some View {
        ZStack {
            if showSplash {
                SplashView()
                    .transition(.opacity)
            } else {
                Group {
                    if container.sessionService.isAuthenticated && sessionReady {
                        if needsOnboarding {
                            OnboardingView {
                                activeOnboardingFlow = false
                            }
                        } else {
                            MainTabView()
                        }
                    } else if let localDataIssue = container.localDataIssue {
                        LocalDataRecoveryView(error: localDataIssue) {
                            await container.resetLocalDataAfterBootstrapFailure()
                        }
                    } else if container.sessionService.isAuthenticated && !sessionReady {
                        // Authenticated but waiting for token refresh
                        ProgressView()
                            .tint(.sanchrPrimary)
                            .task {
                                await refreshSessionToken()
                            }
                    } else {
                        LoginView()
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: container.sessionService.isAuthenticated)
                .animation(.easeInOut(duration: 0.2), value: sessionReady)
                .transition(.opacity)
                .onChange(of: container.sessionService.isAuthenticated) { _, isAuth in
                    if !isAuth {
                        sessionReady = false
                        activeOnboardingFlow = false
                    } else if !hasCompletedProfileBasics {
                        activeOnboardingFlow = true
                    }
                }
                .onChange(of: hasCompletedProfileBasics) { _, hasCompletedProfileBasics in
                    if container.sessionService.isAuthenticated && !hasCompletedProfileBasics {
                        activeOnboardingFlow = true
                    }
                }
            }

            // Lock screen overlay
            if container.appLockManager.isLocked && !showSplash {
                LockScreenView {
                    container.appLockManager.authenticate()
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .screenshotProtection(
            isActive: container.appLockManager.isScreenshotProtectionActive
                || container.privacySettings.sanchrModeEnabled
        )
        .task {
            // If splash has already played this process session (e.g. we're
            // returning from background and SwiftUI re-fired this task), dismiss
            // it immediately and bail — never show splash again after cold launch.
            if RootView.splashHasPlayed {
                showSplash = false
                return
            }
            guard showSplash else { return }
            try? await Task.sleep(for: .seconds(1.15))
            withAnimation(.easeOut(duration: 0.25)) {
                showSplash = false
                RootView.splashHasPlayed = true
            }
        }
        .onChange(of: container.pushManager.pendingAction) { _, action in
            guard action != .none else { return }
            router.routeNotificationAction(action)
            container.pushManager.pendingAction = .none
        }
        .task(id: sessionReady && container.sessionService.isAuthenticated && !needsOnboarding) {
            await offerRestoreIfFreshInstall()
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { restoreSources != nil },
                set: { if !$0 { restoreSources = nil } }
            )
        ) {
            if let restoreSources {
                BackupRestoreOfferView(sources: restoreSources) { _ in
                    markRestoreOfferHandled()
                    self.restoreSources = nil
                }
                .environment(container)
            }
        }
    }

    /// After signing in on a fresh install (no local history yet), look for an
    /// encrypted backup on Sanchr Cloud and in the user's iCloud, and offer to
    /// restore it. Asked once per account per install — skipping is remembered,
    /// so the offer does not nag on every launch.
    private func offerRestoreIfFreshInstall() async {
        guard sessionReady,
            container.sessionService.isAuthenticated,
            !needsOnboarding,
            !restoreOfferChecked
        else { return }
        restoreOfferChecked = true

        guard let userId = container.sessionService.currentUserId,
            !UserDefaults.standard.bool(forKey: Self.restoreOfferKey(for: userId)),
            (try? await container.localDatabase.hasLocalHistory()) == false
        else { return }

        let sources = await container.backupCoordinator.availableRestoreSources()
        guard !sources.isEmpty else { return }
        restoreSources = sources
    }

    private func markRestoreOfferHandled() {
        guard let userId = container.sessionService.currentUserId else { return }
        UserDefaults.standard.set(true, forKey: Self.restoreOfferKey(for: userId))
    }

    private static func restoreOfferKey(for userId: String) -> String {
        "sanchr.restoreOfferHandled.\(userId)"
    }

    /// Refreshes the session token before showing the main UI.
    /// Ensures all subsequent API calls have a valid token.
    /// Also configures the Signal Protocol store with the authenticated user's ID.
    private func refreshSessionToken() async {
        // Always attempt a proactive refresh if the token is expired or within 5 minutes of
        // expiry. This prevents the app opening with a near-expired token that will fail
        // mid-session. `refreshTokenIfExpiringSoon` is a no-op when the token has >5 min left.
        do {
            try await container.sessionService.refreshTokenIfExpiringSoon()
            SanchrLogger.auth.info("Session token validated/refreshed, showing main UI")
        } catch {
            SanchrLogger.auth.error("Session token refresh failed: \(error.localizedDescription)")
            // Token is invalid and can't be refreshed — session state cleared by refreshToken()
        }

        // Configure Signal store with the real user ID (replaces "pending" placeholder)
        if let userId = container.sessionService.currentUserId {
            container.configureSignalStore(userId: userId)
        }

        // Ensure Signal Protocol identity keys exist and key bundle is uploaded
        do {
            if !container.signalKeyManager.hasIdentityKeys {
                SanchrLogger.crypto.info("No identity keys found, generating and uploading key bundle")
                _ = try container.signalKeyManager.generateIdentityIfNeeded()
                try await container.signalKeyManager.uploadInitialKeyBundle()
            } else {
                let currentDeviceId = Int32(container.sessionService.currentDeviceId ?? "") ?? 0
                let currentUserId = container.sessionService.currentUserId ?? ""
                let serverHasBundle = try await container.signalKeyManager.hasCompleteServerBundle(
                    userId: currentUserId,
                    deviceId: currentDeviceId
                )

                if !serverHasBundle {
                    SanchrLogger.crypto.info(
                        "Server bundle missing/incomplete for current device, re-uploading full key bundle"
                    )
                    try await container.signalKeyManager.uploadInitialKeyBundle()
                } else {
                    // Keys exist; just make sure server has enough pre-keys
                    try await container.signalKeyManager.checkAndReplenishPreKeys(threshold: 25)
                }
            }
        } catch {
            SanchrLogger.crypto.warning("Signal key setup failed on startup: \(error.localizedDescription)")
        }

        if container.sessionService.isAuthenticated {
            container.realtimeService.enterForeground()

            // Now that the session is confirmed valid, upload any VoIP push token that
            // arrived before auth was established (deferred to avoid UNAUTHENTICATED
            // triggering a forceRefreshToken() → session-wipe cascade on early launch).
            container.pushManager.uploadPendingVoIPTokenIfNeeded()

            // Warm the privacy cache so enforcement is ready before the first message send.
            do {
                let settingsDataSource = SettingsDataSource(grpcClient: container.grpcClient)
                let settings = try await settingsDataSource.getSettings()
                container.privacySettings.update(from: settings)
            } catch {
                SanchrLogger.settings.warning(
                    "Privacy cache warm-up failed on launch: \(error.localizedDescription)"
                )
            }

            // The block list is part of that enforcement and was not being
            // warmed, so the cache's blocked set was empty for the whole
            // session and nothing was ever blocked. Fetched separately because
            // it comes from the contact service, not the settings one.
            do {
                let contacts = ContactDataSource(
                    grpcClient: container.grpcClient,
                    localDatabase: container.localDatabase
                )
                let blocked = try await contacts.getBlockedList()
                container.privacySettings.update(blockList: Set(blocked))
            } catch {
                SanchrLogger.settings.warning(
                    "Block list warm-up failed on launch: \(error.localizedDescription)"
                )
            }

            // Restore the profile after a reinstall. The Profile Key comes back
            // via iCloud Keychain, but the local name/snapshot does not, so the
            // session has no display name and RootView would send the user back
            // through onboarding. Recover the name (and avatar) by decrypting the
            // encrypted server copy with the restored key, before that decision.
            let localName = container.sessionService.currentDisplayName ?? ""
            if container.profileKeyStore.hasOwnProfileKey(),
                localName.isEmpty || localName == User.serverPlaceholderDisplayName,
                let restored = await container.messageRepository.resolveOwnProfile()
            {
                container.sessionService.updateProfile(
                    displayName: restored.displayName,
                    avatarURL: restored.avatarURL?.absoluteString
                )
            }

            // Authenticating latches activeOnboardingFlow on while the name is
            // still unknown; once the profile is complete — whether restored just
            // now or already present in the session snapshot — the user is fully
            // onboarded, so clear the latch or RootView keeps routing them to the
            // name step. A genuinely new user has no complete profile here, so this
            // leaves their onboarding intact.
            if hasCompletedProfileBasics {
                activeOnboardingFlow = false
            }
        } else {
            container.realtimeService.stop()
        }

        sessionReady = true
    }

}

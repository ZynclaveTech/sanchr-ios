import SwiftUI
import UserNotifications
import SanchrShared

private struct SendableNotificationPayload: @unchecked Sendable {
    let userInfo: [AnyHashable: Any]
}

/// Main entry point for the Sanchr encrypted messaging application.
/// Configures the app environment, dependency injection, APNs delegate,
/// background sync registration, and root scene.
@main
struct SanchrApp: App {
    @UIApplicationDelegateAdaptor(SanchrAppDelegate.self) private var appDelegate
    @State private var container = DependencyContainer()
    @State private var appRouter = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .environment(appRouter)
                .environment(container.syncState)
                .onAppear {
                    configureFonts()
                    configureAppearance()
                    if container.localDataIssue == nil {
                        configureBackgroundSync()
                    }
                }
                .task {
                    do {
                        try await container.connectGRPC()
                    } catch {
                        SanchrLogger.network.error("Failed to connect gRPC channels: \(error.localizedDescription)")
                    }
                    // Wire PushManager after gRPC is connected (it needs notificationService)
                    await MainActor.run {
                        configurePushManager()
                    }
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    handleScenePhaseChange(from: oldPhase, to: newPhase)
                }
        }
    }

    // MARK: - Setup

    /// Registers custom fonts bundled with the application.
    private func configureFonts() {
        // TODO: Register Afacad and Inter font families from Resources/Fonts
        // CTFontManagerRegisterFontsForURL(fontURL, .process, nil)
    }

    /// Applies global appearance overrides for UIKit components embedded in SwiftUI.
    private func configureAppearance() {
        // TODO: Configure UINavigationBar, UITabBar default appearances
        // to match SanchrTheme tokens.
    }

    /// Wire the PushManager as the UNUserNotificationCenter delegate
    /// and share it with the AppDelegate for token forwarding.
    private func configurePushManager() {
        let pushManager = container.pushManager
        UNUserNotificationCenter.current().delegate = pushManager
        appDelegate.pushManager = pushManager

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
            container.realtimeService.enterBackground()
            SanchrLogger.sync.info("App entered background, scheduled background tasks")

        case .active:
            // Check app lock
            lockManager.appDidBecomeActive()
            container.realtimeService.enterForeground()

            // Trigger a foreground sync if needed (>5 min since last sync).
            let syncState = container.syncState
            if syncState.needsSync && container.sessionService.isAuthenticated {
                SanchrLogger.sync.info("App became active, triggering foreground sync")
                Task {
                    await container.syncOrchestrator.startSync()
                }
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
        AppGroupMigration.runIfNeeded()

        // Register background task identifiers early (before app finishes launching).
        SyncOrchestrator.registerBackgroundTasks()

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
    @Environment(DependencyContainer.self) private var container
    @Environment(AppRouter.self) private var router
    @AppStorage("sanchr.activeOnboardingFlow") private var activeOnboardingFlow = false
    @State private var sessionReady = false
    @State private var showSplash = true

    private var hasCompletedProfileBasics: Bool {
        let name = container.sessionService.currentDisplayName ?? ""
        return !name.isEmpty && name != "Sanchr User"
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
        .screenshotProtection(isActive: container.appLockManager.isScreenshotProtectionActive)
        .task {
            guard showSplash else { return }
            try? await Task.sleep(for: .seconds(1.15))
            withAnimation(.easeOut(duration: 0.25)) {
                showSplash = false
            }
        }
        .onChange(of: container.pushManager.pendingAction) { _, action in
            guard action != .none else { return }
            router.routeNotificationAction(action)
            container.pushManager.pendingAction = .none
        }
    }

    /// Refreshes the session token before showing the main UI.
    /// Ensures all subsequent API calls have a valid token.
    /// Also configures the Signal Protocol store with the authenticated user's ID.
    private func refreshSessionToken() async {
        if container.sessionService.isTokenValid {
            SanchrLogger.auth.info("Restored persisted session without immediate token refresh")
        } else {
            do {
                try await container.sessionService.forceRefreshToken()
                SanchrLogger.auth.info("Session token refreshed, showing main UI")
            } catch {
                SanchrLogger.auth.error("Session token refresh failed: \(error.localizedDescription)")
                // Token is invalid and can't be refreshed — session is expired
            }
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
        } else {
            container.realtimeService.stop()
        }

        sessionReady = true
    }

}

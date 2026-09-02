import Foundation
import SanchrShared

/// View model for the settings screen.
/// Manages all settings state with debounced sync to the backend.
@MainActor
@Observable
final class SettingsViewModel {

    // MARK: - Profile State

    var displayName: String = "Sanchr User"
    var phoneNumber: String = "+1 234 567 890"
    var avatarURL: String = ""
    var statusText: String = ""

    // MARK: - Privacy Settings

    var readReceipts: Bool = false
    var onlineStatusVisible: Bool = false
    var typingIndicator: Bool = false
    var profilePhotoVisibility: String = "everyone"

    // MARK: - Security Settings

    var sanchrModeEnabled: Bool = false
    var screenLockEnabled: Bool = false
    var screenLockTimeout: Int32 = 60
    var screenshotProtection: Bool = false
    var biometricLock: Bool = false
    var registrationLockEnabled: Bool = false

    // MARK: - Appearance

    var theme: String = "system"
    var fontSize: String = "medium"
    var chatWallpaper: String = ""

    // MARK: - Storage / Auto-download

    var autoDownloadWifi: String = "all"
    var autoDownloadMobile: String = "photos"
    /// No longer surfaced on iOS: the OS exposes no supported way to detect
    /// roaming, so the setting could never be enforced and its picker was
    /// removed. Still loaded and sent back unchanged so that saving settings
    /// from this client does not overwrite a value another platform stored.
    var autoDownloadRoaming: String = "none"
    var lowDataMode: Bool = false

    // MARK: - Notification Settings

    var messageNotifications: Bool = true
    var groupNotifications: Bool = true
    var callNotifications: Bool = true
    var notificationSound: String = ""
    var notificationVibrate: Bool = true
    var showPreview: Bool = true

    // MARK: - Storage Usage

    var photosBytes: Int64 = 0
    var videosBytes: Int64 = 0
    var documentsBytes: Int64 = 0
    var voiceBytes: Int64 = 0
    var otherBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var limitBytes: Int64 = 0

    // MARK: - UI State

    var isLoading: Bool = false
    var errorMessage: String?

    // MARK: - Privacy Cache

    /// Stored reference so all sync paths can update the cache without API churn.
    private var privacySettings: PrivacySettingsCache?

    // MARK: - Server Baseline

    /// The settings as the server last confirmed them. `nil` until a load has
    /// succeeded.
    ///
    /// `UpdateSettings` replaces the whole row, and `buildSettings()` sends
    /// every field. Without a baseline a failed load left the fields at their
    /// hardcoded defaults, and the first toggle the user touched pushed all
    /// of those defaults over their real settings. The baseline is also what
    /// makes the sync loop-free: a push that would send exactly the baseline
    /// is skipped, so hydrating the fields (which fires every toggle's
    /// `onChange`) and reverting them after a failure never echo back to the
    /// server.
    private var lastServerSettings: Sanchr_Settings_UserSettings?

    var hasLoadedSettings: Bool { lastServerSettings != nil }

    /// Bumped per push so a slow response cannot overwrite the result of a
    /// later one.
    private var pushGeneration = 0

    private static let notLoadedMessage =
        "Your settings haven't loaded, so this change wasn't saved. Close and reopen this screen to try again."

    // MARK: - Debounce

    private var syncWorkItem: DispatchWorkItem?

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    // MARK: - Load Profile from Session

    /// Populates profile fields from the current session state.
    func loadProfile(from sessionService: SessionService) {
        if let name = sessionService.currentDisplayName, !name.isEmpty {
            displayName = name
        }
        if let phone = sessionService.currentPhoneNumber, !phone.isEmpty {
            phoneNumber = phone
        }
        if let avatar = sessionService.currentAvatarURL, !avatar.isEmpty {
            avatarURL = avatar
        }
    }

    // MARK: - Load Settings

    /// Loads settings from the server and syncs them into both the
    /// view model's `@State` fields and the app-wide
    /// `PrivacySettingsCache`.
    ///
    /// `privacySettings` is **required** (not optional) on purpose:
    /// forgetting it would silently leave the cache holding stale
    /// values while the server happily echoes fresh ones, and the
    /// local privacy gates (`canSendReadReceipts` etc.) would lie for
    /// the rest of the session. Every screen that calls this must
    /// thread the container-scoped cache through.
    func loadSettings(
        settingsDataSource: SettingsDataSourceProtocol,
        privacySettings: PrivacySettingsCache,
        appLockManager: AppLockManager? = nil
    ) async {
        self.privacySettings = privacySettings
        isLoading = true
        defer { isLoading = false }

        do {
            let settings = try await settingsDataSource.getSettings()
            lastServerSettings = settings
            applySettings(settings)
            privacySettings.update(from: settings)
            // Sync security prefs to local enforcement
            appLockManager?.syncFromSettings(
                screenLock: settings.screenLockEnabled,
                biometric: settings.biometricLock,
                timeout: settings.screenLockTimeout,
                screenshotProtection: settings.screenshotProtection
            )
            errorMessage = nil
        } catch {
            // The fields stay at their defaults but nothing will be pushed
            // until a load succeeds, so the defaults cannot reach the server.
            SanchrLogger.network.error("Settings load failed: \(error.localizedDescription)")
            errorMessage = "Couldn't load your settings. Close and reopen this screen to try again."
        }
    }

    // MARK: - Load Storage Usage

    /// Measures storage on this device.
    ///
    /// The server's GetStorageUsage RPC returns zeros by design — media types
    /// live inside forward-secure encrypted vault metadata, so the server cannot
    /// compute a breakdown — which made this screen report that the app used no
    /// storage at all. Every byte is local, so it is measured locally.
    func loadStorageUsage() async {
        let usage = await LocalStorageCalculator.calculate()
        photosBytes = usage.photosBytes
        videosBytes = usage.videosBytes
        documentsBytes = usage.documentsBytes
        voiceBytes = usage.voiceBytes
        otherBytes = usage.otherBytes
        totalBytes = usage.totalBytes
        // The bar shows what the app occupies against what the device can still
        // take, so "used" stays meaningful without inventing a quota.
        limitBytes = usage.totalBytes + usage.deviceFreeBytes
    }

    // MARK: - Sync Settings (Debounced)

    /// Debounced sync that waits 500ms after the last change before pushing to server.
    func debouncedSync(settingsDataSource: SettingsDataSourceProtocol) {
        // Mirror straight away rather than waiting for the round trip, so
        // enforcement matches the picker the user is looking at even while
        // the sync is still in flight or the network is down.
        mirrorAutoDownloadSettings()
        syncWorkItem?.cancel()

        guard hasLoadedSettings else {
            errorMessage = Self.notLoadedMessage
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task {
                await self.pushSettings(settingsDataSource: settingsDataSource)
            }
        }

        syncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Pushes the current settings state to the server.
    private func pushSettings(settingsDataSource: SettingsDataSourceProtocol) async {
        let settings = buildSettings()
        // Nothing the server doesn't already have. This is the echo from
        // hydration and from a revert, not a user edit.
        guard settings != lastServerSettings else { return }

        pushGeneration += 1
        let generation = pushGeneration

        do {
            let updated = try await settingsDataSource.updateSettings(settings: settings)
            guard generation == pushGeneration else { return }
            lastServerSettings = updated
            applySettings(updated)
            privacySettings?.update(from: updated)
            errorMessage = nil
            SanchrLogger.network.info("Settings synced to backend")
        } catch {
            guard generation == pushGeneration else { return }
            SanchrLogger.network.error("Settings sync failed: \(error.localizedDescription)")
            revertToServerState()
            errorMessage = "Couldn't save that change. Please try again."
        }
    }

    /// Puts the toggles back to what the server holds after a failed push, so
    /// the screen never shows a state the privacy gates are not enforcing.
    ///
    /// Appearance is the exception: theme, font size and wallpaper take
    /// effect on this device the moment they are picked, and the server copy
    /// only exists for cross-device sync. Reverting those fields would make
    /// the next successful push send the old look while the device shows the
    /// new one.
    private func revertToServerState() {
        guard let last = lastServerSettings else { return }
        applySettings(last, keepingAppearance: true)
    }

    // MARK: - Toggle Sanchr Mode

    /// Set Sanchr Mode to the given value.
    /// `enabled` must be the **desired** state (already reflected in `sanchrModeEnabled`
    /// by the Toggle binding before this is called). We never compute `!sanchrModeEnabled`
    /// here because that would read the post-tap value and invert it, causing a loop.
    func setSanchrMode(enabled: Bool, settingsDataSource: SettingsDataSourceProtocol) async {
        guard let last = lastServerSettings else {
            if sanchrModeEnabled { sanchrModeEnabled = false }
            errorMessage = Self.notLoadedMessage
            return
        }
        // Hydration and the revert below both fire the toggle's onChange with
        // the value the server already holds. Sending it would, on a failure,
        // revert again and call back in here forever.
        guard enabled != last.sanchrModeEnabled else { return }

        do {
            let updated = try await settingsDataSource.toggleSanchrMode(enabled: enabled)
            lastServerSettings?.sanchrModeEnabled = updated.sanchrModeEnabled
            privacySettings?.update(from: updated)
            // Only write sanchrModeEnabled back if the server overrode our value.
            // Writing the same value is a no-op, but it still fires @Observable's
            // change tracking and re-triggers onChange.
            if updated.sanchrModeEnabled != sanchrModeEnabled {
                sanchrModeEnabled = updated.sanchrModeEnabled
            }
            errorMessage = nil
        } catch {
            SanchrLogger.network.error("Sanchr Mode toggle failed: \(error.localizedDescription)")
            if sanchrModeEnabled != last.sanchrModeEnabled {
                sanchrModeEnabled = last.sanchrModeEnabled
            }
            errorMessage = "Couldn't change Sanchr Mode. Please try again."
        }
    }

    // MARK: - Private Helpers

    private func applySettings(
        _ settings: Sanchr_Settings_UserSettings,
        keepingAppearance: Bool = false
    ) {
        readReceipts = settings.readReceipts
        onlineStatusVisible = settings.onlineStatusVisible
        typingIndicator = settings.typingIndicator
        profilePhotoVisibility = settings.profilePhotoVisibility
        sanchrModeEnabled = settings.sanchrModeEnabled
        screenLockEnabled = settings.screenLockEnabled
        screenLockTimeout = settings.screenLockTimeout
        screenshotProtection = settings.screenshotProtection
        biometricLock = settings.biometricLock
        registrationLockEnabled = settings.registrationLockEnabled
        messageNotifications = settings.messageNotifications
        groupNotifications = settings.groupNotifications
        callNotifications = settings.callNotifications
        notificationSound = settings.notificationSound
        notificationVibrate = settings.notificationVibrate
        showPreview = settings.showPreview
        if !keepingAppearance {
            theme = settings.theme
            fontSize = settings.fontSize
            chatWallpaper = settings.chatWallpaper
        }
        autoDownloadWifi = settings.autoDownloadWifi
        autoDownloadMobile = settings.autoDownloadMobile
        autoDownloadRoaming = settings.autoDownloadRoaming
        lowDataMode = settings.lowDataMode
        mirrorAutoDownloadSettings()
    }

    /// Publishes the enforceable auto-download choices where message bubbles
    /// can read them synchronously. Without this the pickers only ever reached
    /// the server, and `AutoDownloadPolicy` had nothing to enforce.
    private func mirrorAutoDownloadSettings() {
        AutoDownloadSettingsStore.store(
            wifi: autoDownloadWifi,
            mobile: autoDownloadMobile
        )
    }

    private func buildSettings() -> Sanchr_Settings_UserSettings {
        var settings = Sanchr_Settings_UserSettings()
        settings.readReceipts = readReceipts
        settings.onlineStatusVisible = onlineStatusVisible
        settings.typingIndicator = typingIndicator
        settings.profilePhotoVisibility = profilePhotoVisibility
        settings.sanchrModeEnabled = sanchrModeEnabled
        settings.screenLockEnabled = screenLockEnabled
        settings.screenLockTimeout = screenLockTimeout
        settings.screenshotProtection = screenshotProtection
        settings.biometricLock = biometricLock
        settings.registrationLockEnabled = registrationLockEnabled
        settings.messageNotifications = messageNotifications
        settings.groupNotifications = groupNotifications
        settings.callNotifications = callNotifications
        settings.notificationSound = notificationSound
        settings.notificationVibrate = notificationVibrate
        settings.showPreview = showPreview
        settings.theme = theme
        settings.fontSize = fontSize
        settings.chatWallpaper = chatWallpaper
        settings.autoDownloadWifi = autoDownloadWifi
        settings.autoDownloadMobile = autoDownloadMobile
        settings.autoDownloadRoaming = autoDownloadRoaming
        settings.lowDataMode = lowDataMode
        return settings
    }

    // MARK: - Formatting

    func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var storageUsagePercentage: Double {
        guard limitBytes > 0 else { return 0 }
        return Double(totalBytes) / Double(limitBytes)
    }
}

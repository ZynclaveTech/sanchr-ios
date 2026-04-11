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
        settingsDataSource: SettingsDataSource,
        privacySettings: PrivacySettingsCache,
        appLockManager: AppLockManager? = nil
    ) async {
        self.privacySettings = privacySettings
        isLoading = true
        defer { isLoading = false }

        do {
            let settings = try await settingsDataSource.getSettings()
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
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Load Storage Usage

    func loadStorageUsage(settingsDataSource: SettingsDataSource) async {
        do {
            let usage = try await settingsDataSource.getStorageUsage()
            photosBytes = usage.photosBytes
            videosBytes = usage.videosBytes
            documentsBytes = usage.documentsBytes
            voiceBytes = usage.voiceBytes
            otherBytes = usage.otherBytes
            totalBytes = usage.totalBytes
            limitBytes = usage.limitBytes
        } catch {
            SanchrLogger.network.error(
                "Failed to load storage usage: \(error.localizedDescription)")
        }
    }

    // MARK: - Sync Settings (Debounced)

    /// Debounced sync that waits 500ms after the last change before pushing to server.
    func debouncedSync(settingsDataSource: SettingsDataSource) {
        syncWorkItem?.cancel()

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
    private func pushSettings(settingsDataSource: SettingsDataSource) async {
        let settings = buildSettings()

        do {
            let updated = try await settingsDataSource.updateSettings(settings: settings)
            applySettings(updated)
            privacySettings?.update(from: updated)
            SanchrLogger.network.info("Settings synced to backend")
        } catch {
            errorMessage = "Failed to save settings. Please try again."
            SanchrLogger.network.error("Settings sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Toggle Sanchr Mode

    /// Set Sanchr Mode to the given value.
    /// `enabled` must be the **desired** state (already reflected in `sanchrModeEnabled`
    /// by the Toggle binding before this is called). We never compute `!sanchrModeEnabled`
    /// here because that would read the post-tap value and invert it, causing a loop.
    func setSanchrMode(enabled: Bool, settingsDataSource: SettingsDataSource) async {
        do {
            let updated = try await settingsDataSource.toggleSanchrMode(enabled: enabled)
            privacySettings?.update(from: updated)
            // Only write sanchrModeEnabled back if the server overrode our value.
            // Writing the same value is a no-op, but it still fires @Observable's
            // change tracking and re-triggers onChange → infinite loop.
            if updated.sanchrModeEnabled != sanchrModeEnabled {
                sanchrModeEnabled = updated.sanchrModeEnabled
            }
        } catch {
            // Revert the Toggle to its pre-tap state on failure.
            sanchrModeEnabled = !enabled
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private Helpers

    private func applySettings(_ settings: Sanchr_Settings_UserSettings) {
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
        theme = settings.theme
        fontSize = settings.fontSize
        chatWallpaper = settings.chatWallpaper
        autoDownloadWifi = settings.autoDownloadWifi
        autoDownloadMobile = settings.autoDownloadMobile
        autoDownloadRoaming = settings.autoDownloadRoaming
        lowDataMode = settings.lowDataMode
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

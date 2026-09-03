import SwiftUI
import UserNotifications
import SanchrShared

/// Notification preferences screen.
/// Matches Figma: notifications-screen.
/// All toggles persist to the backend via the UpdateNotificationPrefs gRPC endpoint.
struct NotificationsView: View {
    @Environment(DependencyContainer.self) private var container

    @State private var viewModel = NotificationsViewModel()

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                if !viewModel.systemPermissionGranted {
                    permissionBanner
                }

                settingsSection(
                    title: "Messages",
                    rows: [
                        AnyView(toggleRow(
                            icon: "message",
                            title: "Message notifications",
                            subtitle: "Receive alerts for new direct messages",
                            isOn: $viewModel.messageNotifications
                        )),
                        AnyView(toggleRow(
                            icon: "text.bubble",
                            title: "Show previews",
                            subtitle: "Display message content in notifications",
                            isOn: $viewModel.showPreviews
                        )),
                        AnyView(toggleRow(
                            icon: "speaker.wave.2",
                            title: "Sound",
                            subtitle: "Play a sound when alerts arrive",
                            isOn: $viewModel.soundEnabled
                        )),
                    ]
                )

                settingsSection(
                    title: "Calls & Groups",
                    rows: [
                        AnyView(toggleRow(
                            icon: "phone",
                            title: "Call notifications",
                            subtitle: "Ring for incoming voice and video calls",
                            isOn: $viewModel.callNotifications
                        )),
                        AnyView(toggleRow(
                            icon: "person.3",
                            title: "Group notifications",
                            subtitle: "Get updates from group conversations",
                            isOn: $viewModel.groupNotifications
                        )),
                        AnyView(toggleRow(
                            icon: "iphone.radiowaves.left.and.right",
                            title: "Vibrate",
                            subtitle: "Use haptics for important alerts",
                            isOn: $viewModel.vibrateEnabled
                        )),
                    ]
                )

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(title: "Delivery")

                    NavigationLink {
                        NotificationSoundPicker(
                            selectedSound: $viewModel.notificationSound,
                            onSelect: {
                                viewModel.syncPreferences(using: container.notificationServiceClient)
                            }
                        )
                    } label: {
                        HStack(spacing: 14) {
                            iconTile(systemName: "music.note")

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Notification tone")
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                                Text(viewModel.notificationSound.isEmpty ? "Default sound" : viewModel.notificationSound.capitalized)
                                    .font(SanchrTypography.caption)
                                    .foregroundColor(SanchrExportColors.textSecondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(SanchrExportColors.textTertiary)
                        }
                        .padding(16)
                        .settingsCard()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .padding(.bottom, 28)
        }
        .sanchrSettingsSubscreenNavigation(title: "Notification Preferences")
        .task { @MainActor in
            await viewModel.checkSystemPermission()
            await viewModel.load(using: settingsDataSource)
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 14) {
            iconTile(systemName: "bell.slash", role: .warning)

            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications Disabled")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(viewModel.systemPermissionUndetermined
                     ? "Turn on notifications to hear about new messages and calls."
                     : "Enable notifications in system settings to receive messages and calls.")
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            // Never asked: the system prompt can still be shown from here.
            // Denied: only Settings can change it.
            if viewModel.systemPermissionUndetermined {
                Button("Turn On") {
                    Task {
                        await container.pushManager.requestAuthorization()
                        await viewModel.checkSystemPermission()
                    }
                }
                .font(SanchrTypography.caption)
                .foregroundColor(.sanchrPrimary)
                .accessibilityHint("Shows the system permission prompt")
            } else {
                Button("Settings") {
                    viewModel.openSystemSettings()
                }
                .font(SanchrTypography.caption)
                .foregroundColor(.sanchrPrimary)
            }
        }
        .padding(18)
        .settingsCard(cornerRadius: 24)
    }

    private func settingsSection(title: String, rows: [AnyView]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionTitle(title: title)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    row

                    if index < rows.count - 1 {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .settingsCard(cornerRadius: 24)
        }
    }

    private func toggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.sanchrPrimary)
                .onChange(of: isOn.wrappedValue) { _, _ in
                    viewModel.syncPreferences(using: container.notificationServiceClient)
                }
        }
        .padding(.vertical, 12)
    }

    private func iconTile(systemName: String, role: SettingsIconRole = .neutral) -> some View {
        SettingsIconTile(systemName: systemName, role: role)
    }
}

// MARK: - Notification Sound Picker

/// Simple picker view for selecting a notification sound.
struct NotificationSoundPicker: View {
    @Binding var selectedSound: String
    var onSelect: () -> Void

    private let sounds = [
        ("Default", ""),
        ("Chime", "chime"),
        ("Bell", "bell"),
        ("Pulse", "pulse"),
        ("Gentle", "gentle"),
        ("None", "none"),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                VStack(spacing: 0) {
                    ForEach(Array(sounds.enumerated()), id: \.offset) { index, sound in
                        let name = sound.0
                        let value = sound.1

                        Button {
                            selectedSound = value
                            onSelect()
                        } label: {
                            HStack {
                                Text(name)
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(SanchrExportColors.textPrimary)

                                Spacer()

                                if selectedSound == value {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.sanchrPrimary)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < sounds.count - 1 {
                            Divider()
                                .padding(.leading, 18)
                        }
                    }
                }
                .background(SanchrExportColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(SanchrExportColors.line.opacity(0.55), lineWidth: 1)
                }
                .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
                .padding(.bottom, 28)
            }
        }
        .sanchrSettingsSubscreenNavigation(title: "Notification Tone")
    }
}

// MARK: - NotificationsViewModel

/// The six notification preferences as the screen presents them, decoded from
/// the stored `UserSettings`.
///
/// Split out from the view model so the decode — chiefly the sound sentinel,
/// where one stored string carries both "which tone" and "sound on at all" —
/// can be tested without standing up a gRPC client.
struct NotificationPreferences: Equatable {
    /// Sentinel the backend stores when the user turns notification sound off.
    static let silentSoundToken = "none"

    var messageNotifications: Bool
    var callNotifications: Bool
    var groupNotifications: Bool
    var showPreviews: Bool
    var soundEnabled: Bool
    var vibrateEnabled: Bool
    var notificationSound: String

    init(from settings: Sanchr_Settings_UserSettings) {
        messageNotifications = settings.messageNotifications
        callNotifications = settings.callNotifications
        groupNotifications = settings.groupNotifications
        showPreviews = settings.showPreview
        vibrateEnabled = settings.notificationVibrate

        // The backend stores "none" when sound is off, so it has to be mapped
        // back to two pieces of state. Anything else — including an empty
        // string, which means "default tone" — leaves sound enabled.
        let sound = settings.notificationSound
        soundEnabled = sound != Self.silentSoundToken
        notificationSound = soundEnabled ? sound : ""
    }
}

/// View model managing notification preference state and backend synchronization.
@MainActor
@Observable
final class NotificationsViewModel {

    // MARK: - Preference State

    var messageNotifications: Bool = true
    var callNotifications: Bool = true
    var groupNotifications: Bool = true
    var showPreviews: Bool = true
    var soundEnabled: Bool = true
    var vibrateEnabled: Bool = true
    var notificationSound: String = ""

    // MARK: - System State

    var systemPermissionGranted: Bool = true
    /// The prompt has never been shown, so it can be shown from the screen.
    var systemPermissionUndetermined: Bool = false
    var errorMessage: String?

    // MARK: - Debounce

    /// Pending sync work item to debounce rapid toggle changes.
    private var syncWorkItem: DispatchWorkItem?

    /// Set while `load` is writing the stored values into the published
    /// properties. Assigning them fires each toggle's `onChange`, which would
    /// otherwise push the values we just read straight back to the server.
    private var isHydrating = false

    // MARK: - Loading

    /// Reads the stored preferences and applies them to the toggles.
    ///
    /// Without this the screen only ever pushed: every open rendered the
    /// hardcoded defaults above regardless of what the user had chosen, and
    /// touching any one toggle then synced that wrong state back, silently
    /// re-enabling notifications the user had turned off.
    ///
    /// The values are read through the settings service rather than the
    /// notification service, which is write-only — it has no "get" RPC. Both
    /// write the same `user_settings` row, so this reads back exactly what
    /// `UpdateNotificationPrefs` last stored.
    func load(using settingsDataSource: SettingsDataSource) async {
        do {
            let prefs = NotificationPreferences(from: try await settingsDataSource.getSettings())
            isHydrating = true
            defer { isHydrating = false }

            messageNotifications = prefs.messageNotifications
            callNotifications = prefs.callNotifications
            groupNotifications = prefs.groupNotifications
            showPreviews = prefs.showPreviews
            vibrateEnabled = prefs.vibrateEnabled
            soundEnabled = prefs.soundEnabled
            notificationSound = prefs.notificationSound
        } catch {
            // Leaving the toggles at their defaults is the safe failure: the
            // user sees notifications as on, which is what they will actually
            // receive until a successful load says otherwise.
            SanchrLogger.push.error(
                "Failed to load notification preferences: \(error.localizedDescription)"
            )
            errorMessage = "Couldn't load your preferences. Close and reopen this screen to try again."
        }
    }


    // MARK: - System Permission Check

    /// Check whether the user has granted notification permission at the system level.
    func checkSystemPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        systemPermissionGranted =
            settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        systemPermissionUndetermined = settings.authorizationStatus == .notDetermined
    }

    /// Open the system Settings app to the Sanchr notification settings.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { @MainActor in
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Backend Sync

    /// Debounced sync of all notification preferences to the backend.
    /// Waits 500ms after the last toggle change before making the gRPC call,
    /// so rapid toggles do not create a storm of network requests.
    func syncPreferences(using service: Sanchr_Notifications_NotificationServiceAsyncClientProtocol) {
        // Applying loaded values is not a user edit; syncing here would echo
        // the server's own state back at it on every open.
        guard !isHydrating else { return }
        syncWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.performSync(using: service)
            }
        }

        syncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Performs the actual gRPC call to update notification preferences.
    private func performSync(using service: Sanchr_Notifications_NotificationServiceAsyncClientProtocol)
        async
    {
        errorMessage = nil

        var request = Sanchr_Notifications_UpdateNotificationPrefsRequest()
        request.messageNotifications = messageNotifications
        request.groupNotifications = groupNotifications
        request.callNotifications = callNotifications
        request.notificationSound =
            soundEnabled ? notificationSound : NotificationPreferences.silentSoundToken
        request.vibrate = vibrateEnabled
        request.showPreview = showPreviews

        do {
            _ = try await service.updateNotificationPrefs(request)
            SanchrLogger.push.info("Notification preferences synced to backend")
        } catch {
            errorMessage = "Failed to save preferences. Please try again."
            SanchrLogger.push.error(
                "Failed to sync notification preferences: \(error.localizedDescription)")
        }
    }
}

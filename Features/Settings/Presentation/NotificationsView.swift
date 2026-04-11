import SwiftUI
import UserNotifications
import SanchrShared

/// Notification preferences screen.
/// Matches Figma: notifications-screen.
/// All toggles persist to the backend via the UpdateNotificationPrefs gRPC endpoint.
struct NotificationsView: View {
    @Environment(DependencyContainer.self) private var container

    @State private var viewModel = NotificationsViewModel()

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
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .sanchrSettingsSubscreenNavigation(title: "Notification Preferences")
        .task { @MainActor in
            await viewModel.checkSystemPermission()
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 14) {
            iconTile(systemName: "bell.slash", role: .warning)

            VStack(alignment: .leading, spacing: 4) {
                Text("Notifications Disabled")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text("Enable notifications in system settings to receive messages and calls.")
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            Button("Settings") {
                viewModel.openSystemSettings()
            }
            .font(SanchrTypography.caption)
            .foregroundColor(.sanchrPrimary)
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
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .sanchrSettingsSubscreenNavigation(title: "Notification Tone")
    }
}

// MARK: - NotificationsViewModel

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
    var errorMessage: String?

    // MARK: - Debounce

    /// Pending sync work item to debounce rapid toggle changes.
    private var syncWorkItem: DispatchWorkItem?

    // MARK: - System Permission Check

    /// Check whether the user has granted notification permission at the system level.
    func checkSystemPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        systemPermissionGranted =
            settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
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
        request.notificationSound = soundEnabled ? notificationSound : "none"
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

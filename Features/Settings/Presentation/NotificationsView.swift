import SwiftUI
import UserNotifications

/// Notification preferences screen.
/// Matches Figma: notifications-screen.
/// All toggles persist to the backend via the UpdateNotificationPrefs gRPC endpoint.
struct NotificationsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(DependencyContainer.self) private var container

    @State private var viewModel = NotificationsViewModel()

    var body: some View {
        List {
            // MARK: - System Permission Banner

            if !viewModel.systemPermissionGranted {
                Section {
                    HStack(spacing: SanchrSpacing.md) {
                        Image(systemName: "bell.slash.fill")
                            .foregroundColor(.sanchrWarning)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: SanchrSpacing.xs) {
                            Text("Notifications Disabled")
                                .font(SanchrTypography.bodyBold)
                            Text("Enable notifications in Settings to receive messages and calls.")
                                .font(SanchrTypography.caption)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        }
                        Spacer()
                        Button("Settings") {
                            viewModel.openSystemSettings()
                        }
                        .font(SanchrTypography.caption.bold())
                        .foregroundColor(.sanchrPrimary)
                    }
                    .padding(.vertical, SanchrSpacing.xs)
                }
                .listRowBackground(Color.sanchrSurface(colorScheme))
            }

            // MARK: - Messages

            Section("Messages") {
                Toggle("Message notifications", isOn: $viewModel.messageNotifications)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.messageNotifications) { _, _ in
                        viewModel.syncPreferences(using: container.notificationServiceClient)
                    }

                Toggle("Show previews", isOn: $viewModel.showPreviews)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.showPreviews) { _, _ in
                        viewModel.syncPreferences(using: container.notificationServiceClient)
                    }

                Toggle("Sound", isOn: $viewModel.soundEnabled)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.soundEnabled) { _, _ in
                        viewModel.syncPreferences(using: container.notificationServiceClient)
                    }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Calls

            Section("Calls") {
                Toggle("Call notifications", isOn: $viewModel.callNotifications)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.callNotifications) { _, _ in
                        viewModel.syncPreferences(using: container.notificationServiceClient)
                    }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Groups

            Section("Groups") {
                Toggle("Group notifications", isOn: $viewModel.groupNotifications)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.groupNotifications) { _, _ in
                        viewModel.syncPreferences(using: container.notificationServiceClient)
                    }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Vibration

            Section {
                Toggle("Vibrate", isOn: $viewModel.vibrateEnabled)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.vibrateEnabled) { _, _ in
                        viewModel.syncPreferences(using: container.notificationServiceClient)
                    }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Notification Tone

            Section {
                NavigationLink {
                    NotificationSoundPicker(
                        selectedSound: $viewModel.notificationSound,
                        onSelect: {
                            viewModel.syncPreferences(using: container.notificationServiceClient)
                        }
                    )
                } label: {
                    HStack {
                        Text("Notification tone")
                            .font(SanchrTypography.body)
                        Spacer()
                        Text(
                            viewModel.notificationSound.isEmpty
                                ? "Default" : viewModel.notificationSound
                        )
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Error

            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .font(SanchrTypography.caption)
                        .foregroundColor(.red)
                }
                .listRowBackground(Color.sanchrSurface(colorScheme))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { @MainActor in
            await viewModel.checkSystemPermission()
        }
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
        List {
            ForEach(sounds, id: \.1) { name, value in
                HStack {
                    Text(name)
                        .font(SanchrTypography.body)
                    Spacer()
                    if selectedSound == value {
                        Image(systemName: "checkmark")
                            .foregroundColor(.sanchrPrimary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedSound = value
                    onSelect()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notification Tone")
        .navigationBarTitleDisplayMode(.inline)
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
    func syncPreferences(using service: Vync_Notifications_NotificationServiceClientProtocol) {
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
    private func performSync(using service: Vync_Notifications_NotificationServiceClientProtocol)
        async
    {
        errorMessage = nil

        var request = Vync_Notifications_UpdateNotificationPrefsRequest()
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

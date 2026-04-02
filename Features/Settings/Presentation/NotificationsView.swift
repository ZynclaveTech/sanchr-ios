import SwiftUI

/// Notification preferences screen.
/// Matches Figma: notifications-screen.
struct NotificationsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var messageNotifications = true
    @State private var callNotifications = true
    @State private var groupNotifications = true
    @State private var showPreviews = true
    @State private var soundEnabled = true

    var body: some View {
        List {
            Section("Messages") {
                Toggle("Message notifications", isOn: $messageNotifications)
                    .tint(.sanchrPrimary)
                Toggle("Show previews", isOn: $showPreviews)
                    .tint(.sanchrPrimary)
                Toggle("Sound", isOn: $soundEnabled)
                    .tint(.sanchrPrimary)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Calls") {
                Toggle("Call notifications", isOn: $callNotifications)
                    .tint(.sanchrPrimary)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section("Groups") {
                Toggle("Group notifications", isOn: $groupNotifications)
                    .tint(.sanchrPrimary)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            Section {
                // TODO: Custom notification tone picker
                HStack {
                    Text("Notification tone")
                        .font(SanchrTypography.body)
                    Spacer()
                    Text("Default")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

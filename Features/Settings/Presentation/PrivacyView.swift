import SwiftUI

/// Privacy settings screen.
/// Matches Figma: privacy-screen.
/// All toggles sync to the backend via SettingsService.UpdateSettings.
struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = SettingsViewModel()
    @State private var lastSeenVisibility = "nobody"
    @State private var aboutVisibility = "everyone"
    @State private var disappearingDefault = "24h"

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    private let visibilityOptions = ["everyone", "contacts", "nobody"]
    private let disappearingOptions = [
        ("Off", "off"),
        ("24 hours", "24h"),
        ("7 days", "7d"),
        ("90 days", "90d"),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                header

                VStack(spacing: 18) {
                    sanchrModeCard
                    accountPrivacySection
                    securityFeaturesSection
                    controlsSection
                    blockedContactsSection
                }
                .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .navigationBarHidden(true)
        .task {
            await viewModel.loadSettings(settingsDataSource: settingsDataSource)
            lastSeenVisibility = viewModel.onlineStatusVisible ? "contacts" : "nobody"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                SanchrIconButton(
                    systemName: "chevron.left",
                    foreground: .white,
                    background: Color.white.opacity(0.12)
                ) {
                    dismiss()
                }

                Text("Privacy & Security")
                    .font(SanchrTypography.cardTitle)
                    .foregroundColor(.white)

                Spacer()
            }

            HStack(spacing: 14) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [SanchrColors.accent, SanchrColors.primary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Protected")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(.white)
                    Text("End-to-end encrypted")
                        .font(SanchrTypography.caption)
                        .foregroundColor(.white.opacity(0.82))
                }

                Spacer()

                Circle()
                    .fill(Color(hex: 0x4ADE80))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
            }
            .padding(16)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(.horizontal, SanchrExportMetrics.screenHorizontal)
        .padding(.top, 12)
        .padding(.bottom, 22)
        .background(
            LinearGradient(
                colors: [SanchrColors.primary, Color(hex: 0x4C1D95)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private var sanchrModeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(SanchrColors.accent)

                        Text("Sanchr Mode")
                            .font(SanchrTypography.cardTitle)
                            .foregroundColor(.white)
                    }

                    Text("Enhanced privacy with hidden previews and a more discreet interface.")
                        .font(SanchrTypography.caption)
                        .foregroundColor(.white.opacity(0.72))
                }

                Spacer()

                Toggle("", isOn: $viewModel.vyncModeEnabled)
                    .labelsHidden()
                    .tint(SanchrColors.accent)
                    .onChange(of: viewModel.vyncModeEnabled) { _, _ in
                        Task {
                            await viewModel.toggleVyncMode(settingsDataSource: settingsDataSource)
                        }
                    }
            }

            HStack(spacing: 12) {
                statPill(icon: "bell.slash.fill", title: "Silent Notifications")
                statPill(icon: "eye.slash.fill", title: "Hidden Previews")
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x111827), Color(hex: 0x0F172A)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var accountPrivacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Account Privacy")

            Menu {
                visibilityMenuSelection(for: $lastSeenVisibility, syncsToBackend: false)
            } label: {
                cardRow(
                    icon: "clock.fill",
                    tint: SanchrColors.primary,
                    background: Color(hex: 0xEEF2FF),
                    title: "Last Seen",
                    subtitle: displayVisibility(lastSeenVisibility),
                    trailing: AnyView(chevron)
                )
            }
            .buttonStyle(.plain)

            Menu {
                visibilityMenuSelection(for: $viewModel.profilePhotoVisibility, syncsToBackend: true)
            } label: {
                cardRow(
                    icon: "person.crop.circle.fill",
                    tint: SanchrColors.accent,
                    background: Color(hex: 0xECFEFF),
                    title: "Profile Photo",
                    subtitle: displayVisibility(viewModel.profilePhotoVisibility),
                    trailing: AnyView(chevron)
                )
            }
            .buttonStyle(.plain)

            Menu {
                visibilityMenuSelection(for: $aboutVisibility, syncsToBackend: false)
            } label: {
                cardRow(
                    icon: "info.circle.fill",
                    tint: Color(hex: 0x7C3AED),
                    background: Color(hex: 0xF3E8FF),
                    title: "About",
                    subtitle: displayVisibility(aboutVisibility),
                    trailing: AnyView(chevron)
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 14) {
                iconTile(systemName: "checkmark.message.fill", tint: Color(hex: 0x16A34A), background: Color(hex: 0xDCFCE7))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Read Receipts")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text(viewModel.readReceipts ? "Enabled" : "Disabled")
                        .font(SanchrTypography.caption)
                        .foregroundColor(SanchrExportColors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $viewModel.readReceipts)
                    .labelsHidden()
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.readReceipts) { _, _ in
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
            }
            .padding(16)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
            }
        }
    }

    private var securityFeaturesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Security Features")

            NavigationLink {
                SecurityView()
            } label: {
                cardRow(
                    icon: "lock.fill",
                    tint: SanchrColors.primary,
                    background: Color(hex: 0xEEF2FF),
                    title: "App Lock",
                    subtitle: "Biometric and timeout controls",
                    trailing: AnyView(chevron)
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                VaultView()
            } label: {
                cardRow(
                    icon: "lock.doc.fill",
                    tint: SanchrColors.accent,
                    background: Color(hex: 0xECFEFF),
                    title: "Secret Vault",
                    subtitle: "Hide sensitive files and chats",
                    trailing: AnyView(chevron)
                )
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(disappearingOptions, id: \.1) { name, value in
                    Button(name) {
                        disappearingDefault = value
                    }
                }
            } label: {
                cardRow(
                    icon: "timer",
                    tint: Color(hex: 0xEA580C),
                    background: Color(hex: 0xFFEDD5),
                    title: "Disappearing Messages",
                    subtitle: disappearingOptions.first(where: { $0.1 == disappearingDefault })?.0 ?? "Off",
                    trailing: AnyView(chevron)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Privacy Controls")

            VStack(spacing: 0) {
                stackedToggleRow(
                    icon: "dot.radiowaves.left.and.right",
                    tint: Color(hex: 0x16A34A),
                    background: Color(hex: 0xDCFCE7),
                    title: "Online Status",
                    subtitle: "Let trusted contacts know when you're active",
                    isOn: $viewModel.onlineStatusVisible
                ) {
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                Divider()
                    .padding(.leading, 56)

                stackedToggleRow(
                    icon: "keyboard.fill",
                    tint: Color(hex: 0x7C3AED),
                    background: Color(hex: 0xF3E8FF),
                    title: "Typing Indicators",
                    subtitle: "Show when you're composing a message",
                    isOn: $viewModel.typingIndicator
                ) {
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
            }
        }
    }

    private var blockedContactsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Blocked Contacts")

            NavigationLink {
                BlockedContactsView()
            } label: {
                cardRow(
                    icon: "hand.raised.fill",
                    tint: Color(hex: 0xDC2626),
                    background: Color(hex: 0xFEE2E2),
                    title: "Blocked contacts",
                    subtitle: "Review and unblock people at any time",
                    trailing: AnyView(chevron)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(SanchrTypography.sectionLabel)
            .tracking(1.2)
            .foregroundColor(SanchrExportColors.textSecondary)
    }

    private func statPill(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.72))
            Text(title)
                .font(SanchrTypography.captionSmall)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func cardRow(
        icon: String,
        tint: Color,
        background: Color,
        title: String,
        subtitle: String,
        trailing: AnyView
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon, tint: tint, background: background)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            trailing
        }
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
        }
    }

    private func stackedToggleRow(
        icon: String,
        tint: Color,
        background: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
        onChange: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon, tint: tint, background: background)

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
                    onChange()
                }
        }
        .padding(.vertical, 12)
    }

    private func iconTile(systemName: String, tint: Color, background: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(SanchrExportColors.surfaceMuted)
            .frame(width: 42, height: 42)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.sanchrPrimary)
            }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(SanchrExportColors.textTertiary)
    }

    @ViewBuilder
    private func visibilityMenuSelection(for binding: Binding<String>, syncsToBackend: Bool) -> some View {
        ForEach(visibilityOptions, id: \.self) { option in
            Button(displayVisibility(option)) {
                binding.wrappedValue = option
                if syncsToBackend {
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }
            }
        }
    }

    private func displayVisibility(_ value: String) -> String {
        switch value {
        case "everyone":
            return "Everyone"
        case "contacts":
            return "My Contacts"
        case "nobody":
            return "Nobody"
        default:
            return value.capitalized
        }
    }
}

/// Sub-screen showing the list of blocked contacts with unblock actions.
struct BlockedContactsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DependencyContainer.self) private var container
    @State private var blockedIDs: [String] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                SanchrCenteredHeader(title: "Blocked Contacts") {
                    SanchrIconButton(systemName: "chevron.left") {
                        dismiss()
                    }
                } trailing: {
                    Color.clear
                }

                if isLoading {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if blockedIDs.isEmpty {
                    VStack(spacing: 12) {
                        Circle()
                            .fill(Color(hex: 0xF3F4F6))
                            .frame(width: 72, height: 72)
                            .overlay {
                                Image(systemName: "hand.raised.slash.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundColor(SanchrExportColors.textTertiary)
                            }
                        Text("No blocked contacts")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text("You can block someone from any conversation if needed.")
                            .font(SanchrTypography.caption)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    VStack(spacing: 12) {
                        ForEach(blockedIDs, id: \.self) { userId in
                            HStack(spacing: 14) {
                                Circle()
                                    .fill(Color(hex: 0xFEE2E2))
                                    .frame(width: 42, height: 42)
                                    .overlay {
                                        Image(systemName: "person.fill")
                                            .foregroundColor(.sanchrError)
                                    }

                                Text(shortID(userId))
                                    .font(SanchrTypography.bodyBold)
                                    .foregroundColor(SanchrExportColors.textPrimary)

                                Spacer()

                                Button("Unblock") {
                                    Task { await unblock(userId: userId) }
                                }
                                .font(SanchrTypography.caption)
                                .foregroundColor(.sanchrError)
                            }
                            .padding(16)
                            .background(SanchrExportColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
                            }
                        }
                    }
                    .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
                    .padding(.bottom, 28)
                }
            }
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .navigationBarHidden(true)
        .task {
            await loadBlocked()
        }
    }

    private func shortID(_ userId: String) -> String {
        let prefix = String(userId.prefix(12))
        return userId.count > 12 ? "\(prefix)..." : prefix
    }

    private func loadBlocked() async {
        isLoading = true
        defer { isLoading = false }

        let dataSource = ContactDataSource(
            grpcClient: container.grpcClient,
            localDatabase: container.localDatabase
        )
        do {
            blockedIDs = try await dataSource.getBlockedList()
        } catch {
            SanchrLogger.sync.error("Failed to load blocked list: \(error.localizedDescription)")
        }
    }

    private func unblock(userId: String) async {
        let dataSource = ContactDataSource(
            grpcClient: container.grpcClient,
            localDatabase: container.localDatabase
        )
        do {
            try await dataSource.unblockContact(userId: userId)
            blockedIDs.removeAll { $0 == userId }
        } catch {
            SanchrLogger.sync.error("Failed to unblock: \(error.localizedDescription)")
        }
    }
}

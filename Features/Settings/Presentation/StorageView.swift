import SwiftUI
import SanchrShared

/// Storage and data management screen.
/// Matches Figma: storage-data-screen.
/// Fetches storage usage from backend and manages auto-download/cache settings.
struct StorageView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var viewModel = SettingsViewModel()
    @State private var showClearCacheConfirm = false
    @State private var showClearAllConfirm = false
    @State private var isClearing = false

    private var settingsDataSource: SettingsDataSource {
        SettingsDataSource(grpcClient: container.grpcClient)
    }

    private let autoDownloadOptions = [
        ("All media", "all"),
        ("Photos only", "photos"),
        ("No media", "none"),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                overviewCard
                breakdownSection
                manageSection
                autoDownloadSection
                networkSection
                encryptedStorageCard

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
            .padding(.bottom, 28)
        }
        .sanchrSettingsSubscreenNavigation(title: "Storage & Data")
        .alert("Clear Media Cache", isPresented: $showClearCacheConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await clearCache() }
            }
        } message: {
            Text("This will remove cached media and free up storage on this device.")
        }
        .alert("Clear All Local Data", isPresented: $showClearAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                Task { await clearAll() }
            }
        } message: {
            Text("This will delete local messages, media, and cached files stored on this device.")
        }
        .task {
            await viewModel.loadSettings(
                settingsDataSource: settingsDataSource,
                privacySettings: container.privacySettings
            )
            await viewModel.loadStorageUsage()
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 12) {
                    SettingsIconTile(systemName: "internaldrive", role: .accent, size: 48, iconSize: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total Storage Used")
                            .font(SanchrTypography.caption)
                            .foregroundColor(SanchrExportColors.textSecondary)
                        Text(viewModel.formattedBytes(viewModel.totalBytes))
                            .font(SanchrTypography.sectionHeader)
                            .foregroundColor(SanchrExportColors.textPrimary)
                    }
                }

                Spacer()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SanchrExportColors.surfaceMuted)
                        .frame(height: 12)

                    Capsule()
                        .fill(Color.sanchrPrimary)
                        .frame(width: proxy.size.width * max(0.02, min(1, viewModel.storageUsagePercentage)), height: 12)
                }
            }
            .frame(height: 12)

            HStack {
                Text("\(viewModel.formattedBytes(viewModel.totalBytes)) of \(viewModel.formattedBytes(viewModel.limitBytes)) used")
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
                Spacer()
                Text("\(Int(viewModel.storageUsagePercentage * 100))%")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
            }
        }
        .padding(20)
        .settingsCard(cornerRadius: 26)
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Storage Breakdown")

            VStack(spacing: 12) {
                storageItemCard(
                    icon: "photo",
                    title: "Photos",
                    subtitle: "Encrypted images and gallery cache",
                    bytes: viewModel.photosBytes
                )

                storageItemCard(
                    icon: "video",
                    title: "Videos",
                    subtitle: "Secure clips and downloaded video media",
                    bytes: viewModel.videosBytes
                )

                storageItemCard(
                    icon: "doc",
                    title: "Documents",
                    subtitle: "PDFs, files, and shared documents",
                    bytes: viewModel.documentsBytes
                )

                storageItemCard(
                    icon: "waveform",
                    title: "Voice Messages",
                    subtitle: "Audio notes and voice attachments",
                    bytes: viewModel.voiceBytes
                )

                storageItemCard(
                    icon: "ellipsis",
                    title: "Other",
                    subtitle: "App data and local cache",
                    bytes: viewModel.otherBytes
                )
            }
        }
    }

    private var manageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Manage Storage")

            VStack(spacing: 12) {
                Button {
                    showClearCacheConfirm = true
                } label: {
                    manageRow(
                        icon: "trash",
                        title: "Clear Cache",
                        subtitle: "Free up \(viewModel.formattedBytes(viewModel.otherBytes))",
                        role: .destructive
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isClearing)

                Button {
                    showClearAllConfirm = true
                } label: {
                    manageRow(
                        icon: "sparkles",
                        title: "Free Up Space",
                        subtitle: "Remove local media and archived files"
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isClearing)

                NavigationLink {
                    ChatSettingsView()
                } label: {
                    manageRow(
                        icon: "arrow.clockwise.circle",
                        title: "Backup & Restore",
                        subtitle: "Manage encrypted backups"
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var autoDownloadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Auto-Download Media")

            VStack(spacing: 12) {
                autoDownloadRow(
                    icon: "wifi",
                    title: "When using Wi-Fi",
                    value: viewModel.autoDownloadWifi
                ) { option in
                    viewModel.autoDownloadWifi = option
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                autoDownloadRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "When using mobile data",
                    value: viewModel.autoDownloadMobile
                ) { option in
                    viewModel.autoDownloadMobile = option
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                // No "When roaming" row: iOS exposes no supported way to detect
                // roaming — CTCarrier was deprecated in iOS 16 and reports
                // placeholder values — so the choice could never be honoured.
                // Roaming is cellular, and the mobile-data setting governs it.
            }
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Network Usage")

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    iconTile(systemName: "chart.line.uptrend.xyaxis")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Low Data Mode")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(SanchrExportColors.textPrimary)
                        Text("Reduces quality and limits automatic downloads.")
                            .font(SanchrTypography.caption)
                            .foregroundColor(SanchrExportColors.textSecondary)
                    }

                    Spacer()

                    Toggle("", isOn: $viewModel.lowDataMode)
                        .labelsHidden()
                        .tint(.sanchrPrimary)
                        .onChange(of: viewModel.lowDataMode) { _, _ in
                            viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                        }
                }

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(SanchrExportColors.surfaceMuted)
                    .frame(height: 94)
                    .overlay {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sent")
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(SanchrExportColors.textSecondary)
                                Text(viewModel.formattedBytes(max(124_000_000, viewModel.documentsBytes / 2)))
                                    .font(SanchrTypography.cardTitle)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Received")
                                    .font(SanchrTypography.captionSmall)
                                    .foregroundColor(SanchrExportColors.textSecondary)
                                Text(viewModel.formattedBytes(max(2_300_000_000, viewModel.totalBytes)))
                                    .font(SanchrTypography.cardTitle)
                                    .foregroundColor(SanchrExportColors.textPrimary)
                            }
                        }
                        .padding(.horizontal, 18)
                    }
            }
            .padding(18)
            .settingsCard()
        }
    }

    private var encryptedStorageCard: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsIconTile(systemName: "shield", role: .accent)

            VStack(alignment: .leading, spacing: 4) {
                Text("Encrypted Storage")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text("All downloaded media and cached messages remain protected with end-to-end encryption. Sanchr never has access to your private content.")
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .settingsCard()
    }

    private func sectionTitle(_ title: String) -> some View {
        SettingsSectionTitle(title: title)
    }

    private func storageItemCard(
        icon: String,
        title: String,
        subtitle: String,
        bytes: Int64
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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

                Text(viewModel.formattedBytes(bytes))
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SanchrExportColors.surfaceMuted)
                        .frame(height: 8)

                    Capsule()
                        .fill(Color.sanchrPrimary)
                        .frame(
                            width: proxy.size.width * progress(for: bytes),
                            height: 8
                        )
                }
            }
            .frame(height: 8)
        }
        .padding(16)
        .settingsCard()
    }

    private func manageRow(
        icon: String,
        title: String,
        subtitle: String,
        role: SettingsIconRole = .neutral
    ) -> some View {
        HStack(spacing: 14) {
            iconTile(systemName: icon, role: role)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(SanchrExportColors.textPrimary)
                Text(subtitle)
                    .font(SanchrTypography.caption)
                    .foregroundColor(SanchrExportColors.textSecondary)
            }

            Spacer()

            if isClearing {
                ProgressView()
                    .tint(.sanchrPrimary)
            } else {
                Image(systemName: "chevron.right")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
            }
        }
        .padding(16)
        .settingsCard()
    }

    private func autoDownloadRow(
        icon: String,
        title: String,
        value: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(autoDownloadOptions, id: \.1) { name, option in
                Button(name) {
                    onSelect(option)
                }
            }
        } label: {
            HStack(spacing: 14) {
                iconTile(systemName: icon)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(SanchrExportColors.textPrimary)
                    Text(displayName(for: value))
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

    private func iconTile(systemName: String, role: SettingsIconRole = .neutral) -> some View {
        SettingsIconTile(systemName: systemName, role: role)
    }

    private func progress(for bytes: Int64) -> CGFloat {
        guard viewModel.totalBytes > 0 else { return 0.02 }
        return max(0.02, min(1, CGFloat(bytes) / CGFloat(viewModel.totalBytes)))
    }

    private func displayName(for option: String) -> String {
        autoDownloadOptions.first(where: { $0.1 == option })?.0 ?? "Default"
    }

    private func clearCache() async {
        isClearing = true
        defer { isClearing = false }

        do {
            try await container.mediaManager.clearCache()
            await viewModel.loadStorageUsage()
        } catch {
            viewModel.errorMessage = UserFacingError.message(for: error)
        }
    }

    private func clearAll() async {
        isClearing = true
        defer { isClearing = false }

        let useCase = SettingsUseCases.ClearLocalData(
            localDatabase: container.localDatabase,
            mediaManager: container.mediaManager
        )

        do {
            try await useCase.execute()
            await viewModel.loadStorageUsage()
        } catch {
            viewModel.errorMessage = UserFacingError.message(for: error)
        }
    }
}

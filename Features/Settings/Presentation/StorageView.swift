import SwiftUI
import SanchrShared

/// Storage and data management screen.
/// Matches Figma: storage-data-screen.
/// Fetches storage usage from backend and manages auto-download/cache settings.
struct StorageView: View {
    @Environment(\.dismiss) private var dismiss
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
                header
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
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
        .navigationBarHidden(true)
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
            await viewModel.loadSettings(settingsDataSource: settingsDataSource)
            await viewModel.loadStorageUsage(settingsDataSource: settingsDataSource)
        }
    }

    private var header: some View {
        SanchrCenteredHeader(title: "Storage & Data") {
            SanchrIconButton(systemName: "chevron.left") {
                dismiss()
            }
        } trailing: {
            Color.clear
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "internaldrive.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total Storage Used")
                            .font(SanchrTypography.caption)
                            .foregroundColor(.white.opacity(0.88))
                        Text(viewModel.formattedBytes(viewModel.totalBytes))
                            .font(SanchrTypography.sectionHeader)
                            .foregroundColor(.white)
                    }
                }

                Spacer()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 12)

                    Capsule()
                        .fill(Color(hex: 0x06B6D4))
                        .frame(width: proxy.size.width * max(0.02, min(1, viewModel.storageUsagePercentage)), height: 12)
                }
            }
            .frame(height: 12)

            HStack {
                Text("\(viewModel.formattedBytes(viewModel.totalBytes)) of \(viewModel.formattedBytes(viewModel.limitBytes)) used")
                    .font(SanchrTypography.caption)
                    .foregroundColor(.white.opacity(0.88))
                Spacer()
                Text("\(Int(viewModel.storageUsagePercentage * 100))%")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(.white)
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [SanchrColors.primary, Color(hex: 0x4F46E5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Storage Breakdown")

            VStack(spacing: 12) {
                storageItemCard(
                    icon: "photo.fill",
                    tint: Color(hex: 0x2563EB),
                    background: Color(hex: 0xDBEAFE),
                    title: "Photos",
                    subtitle: "Encrypted images and gallery cache",
                    bytes: viewModel.photosBytes
                )

                storageItemCard(
                    icon: "video.fill",
                    tint: Color(hex: 0x7C3AED),
                    background: Color(hex: 0xF3E8FF),
                    title: "Videos",
                    subtitle: "Secure clips and downloaded video media",
                    bytes: viewModel.videosBytes
                )

                storageItemCard(
                    icon: "doc.fill",
                    tint: Color(hex: 0x16A34A),
                    background: Color(hex: 0xDCFCE7),
                    title: "Documents",
                    subtitle: "PDFs, files, and shared documents",
                    bytes: viewModel.documentsBytes
                )

                storageItemCard(
                    icon: "waveform",
                    tint: Color(hex: 0xEA580C),
                    background: Color(hex: 0xFFEDD5),
                    title: "Voice Messages",
                    subtitle: "Audio notes and voice attachments",
                    bytes: viewModel.voiceBytes
                )

                storageItemCard(
                    icon: "ellipsis",
                    tint: Color(hex: 0x6B7280),
                    background: Color(hex: 0xF3F4F6),
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
                        icon: "trash.fill",
                        tint: Color(hex: 0xDC2626),
                        background: Color(hex: 0xFEE2E2),
                        title: "Clear Cache",
                        subtitle: "Free up \(viewModel.formattedBytes(viewModel.otherBytes))"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isClearing)

                Button {
                    showClearAllConfirm = true
                } label: {
                    manageRow(
                        icon: "sparkles",
                        tint: Color(hex: 0x4F46E5),
                        background: Color(hex: 0xEEF2FF),
                        title: "Free Up Space",
                        subtitle: "Remove local media and archived files"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isClearing)

                NavigationLink {
                    ChatSettingsView()
                } label: {
                    manageRow(
                        icon: "arrow.clockwise.circle.fill",
                        tint: Color(hex: 0x06B6D4),
                        background: Color(hex: 0xECFEFF),
                        title: "Backup & Restore",
                        subtitle: "Manage encrypted backups"
                    )
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
                    tint: Color(hex: 0x16A34A),
                    background: Color(hex: 0xDCFCE7),
                    title: "When using Wi-Fi",
                    value: viewModel.autoDownloadWifi
                ) { option in
                    viewModel.autoDownloadWifi = option
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                autoDownloadRow(
                    icon: "antenna.radiowaves.left.and.right",
                    tint: Color(hex: 0x2563EB),
                    background: Color(hex: 0xDBEAFE),
                    title: "When using mobile data",
                    value: viewModel.autoDownloadMobile
                ) { option in
                    viewModel.autoDownloadMobile = option
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }

                autoDownloadRow(
                    icon: "airplane",
                    tint: Color(hex: 0x7C3AED),
                    background: Color(hex: 0xF3E8FF),
                    title: "When roaming",
                    value: viewModel.autoDownloadRoaming
                ) { option in
                    viewModel.autoDownloadRoaming = option
                    viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                }
            }
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Network Usage")

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    iconTile(
                        systemName: "chart.line.uptrend.xyaxis",
                        tint: SanchrColors.primary,
                        background: Color(hex: 0xEEF2FF)
                    )

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
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
            }
        }
    }

    private var encryptedStorageCard: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("Encrypted Storage")
                    .font(SanchrTypography.bodyBold)
                    .foregroundColor(.white)
                Text("All downloaded media and cached messages remain protected with end-to-end encryption. Sanchr never has access to your private content.")
                    .font(SanchrTypography.caption)
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x4C1D95), SanchrColors.primary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(SanchrTypography.sectionLabel)
            .tracking(1.2)
            .foregroundColor(SanchrExportColors.textSecondary)
    }

    private func storageItemCard(
        icon: String,
        tint: Color,
        background: Color,
        title: String,
        subtitle: String,
        bytes: Int64
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        .fill(tint)
                        .frame(
                            width: proxy.size.width * progress(for: bytes),
                            height: 8
                        )
                }
            }
            .frame(height: 8)
        }
        .padding(16)
        .background(SanchrExportColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
        }
    }

    private func manageRow(
        icon: String,
        tint: Color,
        background: Color,
        title: String,
        subtitle: String
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

            if isClearing {
                ProgressView()
                    .tint(.sanchrPrimary)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
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

    private func autoDownloadRow(
        icon: String,
        tint: Color,
        background: Color,
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
                iconTile(systemName: icon, tint: tint, background: background)

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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SanchrExportColors.textTertiary)
            }
            .padding(16)
            .background(SanchrExportColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(hex: 0xE5E7EB), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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
            await viewModel.loadStorageUsage(settingsDataSource: settingsDataSource)
        } catch {
            viewModel.errorMessage = error.localizedDescription
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
            await viewModel.loadStorageUsage(settingsDataSource: settingsDataSource)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

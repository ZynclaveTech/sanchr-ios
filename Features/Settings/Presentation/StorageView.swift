import SwiftUI

/// Storage and data management screen.
/// Matches Figma: storage-data-screen.
/// Fetches storage usage from backend and manages auto-download/cache settings.
struct StorageView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
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
        List {
            // MARK: - Storage Usage Overview
            Section("Storage Usage") {
                // Total usage bar
                VStack(alignment: .leading, spacing: SanchrSpacing.xs) {
                    HStack {
                        Text("Total")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        Spacer()
                        Text("\(viewModel.formattedBytes(viewModel.totalBytes)) / \(viewModel.formattedBytes(viewModel.limitBytes))")
                            .font(SanchrTypography.caption)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    }

                    ProgressView(value: viewModel.storageUsagePercentage)
                        .tint(viewModel.storageUsagePercentage > 0.9 ? .sanchrError : .sanchrPrimary)
                }
                .padding(.vertical, SanchrSpacing.xxs)

                // Category breakdown
                storageRow(
                    icon: "photo.fill",
                    color: .sanchrPrimary,
                    label: "Photos",
                    bytes: viewModel.photosBytes,
                    total: viewModel.totalBytes
                )

                storageRow(
                    icon: "video.fill",
                    color: .sanchrAccent,
                    label: "Videos",
                    bytes: viewModel.videosBytes,
                    total: viewModel.totalBytes
                )

                storageRow(
                    icon: "doc.fill",
                    color: .sanchrWarning,
                    label: "Documents",
                    bytes: viewModel.documentsBytes,
                    total: viewModel.totalBytes
                )

                storageRow(
                    icon: "waveform",
                    color: .sanchrSuccess,
                    label: "Voice Messages",
                    bytes: viewModel.voiceBytes,
                    total: viewModel.totalBytes
                )

                storageRow(
                    icon: "ellipsis.circle.fill",
                    color: Color.sanchrTextTertiary(colorScheme),
                    label: "Other",
                    bytes: viewModel.otherBytes,
                    total: viewModel.totalBytes
                )
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Auto-Download (Wi-Fi)
            Section("Auto-Download - Wi-Fi") {
                ForEach(autoDownloadOptions, id: \.1) { name, value in
                    HStack {
                        Text(name)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        Spacer()
                        if viewModel.autoDownloadWifi == value {
                            Image(systemName: "checkmark")
                                .foregroundColor(.sanchrPrimary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.autoDownloadWifi = value
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Auto-Download (Mobile)
            Section("Auto-Download - Mobile Data") {
                ForEach(autoDownloadOptions, id: \.1) { name, value in
                    HStack {
                        Text(name)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        Spacer()
                        if viewModel.autoDownloadMobile == value {
                            Image(systemName: "checkmark")
                                .foregroundColor(.sanchrPrimary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.autoDownloadMobile = value
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Auto-Download (Roaming)
            Section("Auto-Download - Roaming") {
                ForEach(autoDownloadOptions, id: \.1) { name, value in
                    HStack {
                        Text(name)
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        Spacer()
                        if viewModel.autoDownloadRoaming == value {
                            Image(systemName: "checkmark")
                                .foregroundColor(.sanchrPrimary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.autoDownloadRoaming = value
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Low Data Mode
            Section {
                Toggle("Low data mode", isOn: $viewModel.lowDataMode)
                    .tint(.sanchrPrimary)
                    .onChange(of: viewModel.lowDataMode) { _, _ in
                        viewModel.debouncedSync(settingsDataSource: settingsDataSource)
                    }

                Text("Reduces data usage by compressing media and limiting background activity.")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // MARK: - Clear Cache
            Section {
                Button(role: .destructive) {
                    showClearCacheConfirm = true
                } label: {
                    HStack {
                        Text("Clear media cache")
                            .font(SanchrTypography.body)
                        Spacer()
                        if isClearing {
                            ProgressView()
                        }
                    }
                }
                .disabled(isClearing)

                Button(role: .destructive) {
                    showClearAllConfirm = true
                } label: {
                    Text("Clear all local data")
                        .font(SanchrTypography.body)
                }
                .disabled(isClearing)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Storage & Data")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear Media Cache", isPresented: $showClearCacheConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await clearCache() }
            }
        } message: {
            Text("This will remove all cached media. Downloaded files will need to be re-downloaded.")
        }
        .alert("Clear All Local Data", isPresented: $showClearAllConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                Task { await clearAll() }
            }
        } message: {
            Text("This will delete all local messages, media, and cached data. This cannot be undone.")
        }
        .task {
            await viewModel.loadSettings(settingsDataSource: settingsDataSource)
            await viewModel.loadStorageUsage(settingsDataSource: settingsDataSource)
        }
    }

    // MARK: - Storage Row

    private func storageRow(
        icon: String,
        color: Color,
        label: String,
        bytes: Int64,
        total: Int64
    ) -> some View {
        HStack(spacing: SanchrSpacing.sm) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)

            Text(label)
                .font(SanchrTypography.body)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))

            Spacer()

            Text(viewModel.formattedBytes(bytes))
                .font(SanchrTypography.caption)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))

            // Mini progress bar
            GeometryReader { geo in
                let fraction = total > 0 ? CGFloat(bytes) / CGFloat(total) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.sanchrBorder(colorScheme))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * fraction, height: 4)
                }
            }
            .frame(width: 60, height: 4)
        }
    }

    // MARK: - Clear Actions

    private func clearCache() async {
        isClearing = true
        defer { isClearing = false }

        do {
            try await container.mediaManager.clearCache()
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
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

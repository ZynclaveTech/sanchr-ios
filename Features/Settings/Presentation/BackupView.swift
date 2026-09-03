import SwiftUI
import SanchrShared

// MARK: - BackupView

struct BackupView: View {
    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme

    @State private var backupHistory: [BackupListEntry] = []
    @State private var historyState: HistoryLoadState = .idle
    @State private var showingRecoveryKeySheet = false
    @State private var showingRevealedKeySheet = false
    @State private var revealedKey: String?
    @State private var showingRestoreSheet = false
    @State private var restoreTargetId: String?
    @State private var restoreRecoveryKey = ""
    @State private var lastLoadError: String?
    @State private var showDisableAlert = false
    @State private var showDeleteAlert = false

    private enum HistoryLoadState {
        case idle, loading, loaded, failed
    }

    var body: some View {
        List {
            if container.backupCoordinator.isEnabled {
                enabledContent
            } else {
                disabledContent
            }
        }
        .listStyle(.insetGrouped)
        .sanchrSettingsSubscreenNavigation(title: "Backup & Recovery")
        .task {
            container.backupCoordinator.reload()
            if container.backupCoordinator.isEnabled {
                await loadHistory()
            }
        }
        .sheet(isPresented: $showingRecoveryKeySheet) {
            BackupRecoveryKeySheet(
                recoveryKey: container.backupCoordinator.pendingRecoveryKey ?? "",
                displayOnly: false,
                onConfirm: {
                    Task {
                        await container.backupCoordinator.confirmPendingRecoveryKey()
                        showingRecoveryKeySheet = false
                    }
                },
                onCancel: {
                    container.backupCoordinator.cancelPendingRecoveryKey()
                    showingRecoveryKeySheet = false
                }
            )
        }
        .sheet(isPresented: $showingRevealedKeySheet) {
            BackupRecoveryKeySheet(
                recoveryKey: revealedKey ?? "",
                displayOnly: true,
                onConfirm: {},
                onCancel: { showingRevealedKeySheet = false }
            )
        }
        .sheet(isPresented: $showingRestoreSheet) {
            BackupRestoreSheet(
                recoveryKey: $restoreRecoveryKey,
                backupId: restoreTargetId,
                isProcessing: container.backupCoordinator.isProcessing,
                onRestore: {
                    let key = restoreRecoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        if let backupId = restoreTargetId {
                            await container.backupCoordinator.restoreBackup(
                                backupId: backupId,
                                with: key.isEmpty ? nil : key
                            )
                        } else {
                            await container.backupCoordinator.restoreLatestBackup(
                                with: key.isEmpty ? nil : key
                            )
                        }
                        if container.backupCoordinator.errorMessage == nil {
                            showingRestoreSheet = false
                        }
                    }
                },
                onCancel: { showingRestoreSheet = false }
            )
        }
    }

    // MARK: - Disabled State

    private var disabledContent: some View {
        Group {
            // Hero card
            Section {
                VStack(spacing: SanchrSpacing.md) {
                    SettingsIconTile(systemName: "shield", role: .accent, size: 56, iconSize: 24)

                    Text("Protect your chat history")
                        .font(SanchrTypography.sectionHeader)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                        .multilineTextAlignment(.center)

                    Text("Encrypted backups let you restore messages on a new device. Only you can read them — not even Sanchr.")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        .multilineTextAlignment(.center)

                    Button {
                        container.backupCoordinator.prepareEnableBackups()
                        showingRecoveryKeySheet = true
                    } label: {
                        Text("Enable Backup")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.sanchrPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.md))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, SanchrSpacing.sm)
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // What gets backed up
            Section {
                backupContentRow(icon: "message", title: "Messages & conversations", subtitle: "All chats, group info, contacts")
                backupContentRow(icon: "lock.doc", title: "Vault items", subtitle: "Encrypted vault media & keys")
                backupContentRow(icon: "photo.on.rectangle", title: "Photos & videos", subtitle: "Re-downloaded from Sanchr on restore")
            } header: {
                SettingsSectionTitle(title: "What gets backed up")
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // Restore row — always visible
            Section {
                restoreRow
            } header: {
                SettingsSectionTitle(title: "Restore")
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
    }

    // MARK: - Enabled State

    private var enabledContent: some View {
        Group {
            // Status card
            Section {
                statusCard
                if let errorMessage = container.backupCoordinator.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrError)
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // Destinations
            Section {
                destinationRow(
                    icon: "externaldrive.badge.icloud",
                    title: "Sanchr Cloud",
                    subtitle: "Chats only · encrypted before upload",
                    destination: .sanchrCloud
                )
                destinationRow(
                    icon: "icloud",
                    title: "iCloud",
                    subtitle: "Chats & media · stored in your iCloud",
                    destination: .iCloud
                )
            } header: {
                Text("BACK UP TO")
            } footer: {
                Text(
                    "iCloud backups are encrypted on your device and saved to your own iCloud storage. Sanchr never sees, stores, or tracks them — our servers are not contacted at all."
                )
                .font(SanchrTypography.captionSmall)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // Automatic backup
            Section {
                Picker("Frequency", selection: frequencyBinding) {
                    Text("Off").tag(BackupFrequency.off)
                    Text("Daily").tag(BackupFrequency.daily)
                    Text("Weekly").tag(BackupFrequency.weekly)
                }
                .font(SanchrTypography.body)
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                if destinationsBinding.wrappedValue.contains(.iCloud) {
                    Toggle(isOn: wifiOnlyMediaBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Media over Wi-Fi only")
                                .font(SanchrTypography.body)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                            Text("Photos & videos wait for Wi-Fi")
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        }
                    }
                    .tint(.sanchrPrimary)
                }
            } header: {
                Text("AUTOMATIC BACKUP")
            } footer: {
                Text(
                    frequencyBinding.wrappedValue == .off
                        ? "Automatic backup is off. Your chats are only backed up when you tap Back Up Now."
                        : "Backs up automatically once \(frequencyBinding.wrappedValue == .daily ? "a day" : "a week") when you use the app."
                )
                .font(SanchrTypography.captionSmall)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // Recovery Key
            Section {
                Button {
                    Task {
                        do {
                            revealedKey = try await container.backupCoordinator.revealRecoveryKey()
                            showingRevealedKeySheet = true
                        } catch {
                            container.backupCoordinator.reportError(error)
                        }
                    }
                } label: {
                    Label("View Recovery Key", systemImage: "key")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    container.backupCoordinator.rotateRecoveryKey()
                    showingRecoveryKeySheet = true
                } label: {
                    Label("Rotate Recovery Key", systemImage: "arrow.clockwise")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("RECOVERY KEY")
            } footer: {
                Text(
                    "Your recovery key is the only thing that can unlock a backup. Every backup — Sanchr Cloud or iCloud — is encrypted with it before it leaves this device, so when you reinstall or move to a new phone, you will be asked for this key to bring your chats back. Sanchr cannot reset it or recover it for you: without the key, no one (including us) can read your backup. Write it down and keep it somewhere safe."
                )
                .font(SanchrTypography.captionSmall)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // Backup History
            Section("BACKUP HISTORY") {
                backupHistoryRows
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // Restore
            Section("RESTORE") {
                restoreRow
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // Danger zone
            Section {
                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Text("Delete All Backups")
                        .font(SanchrTypography.body)
                        .foregroundColor(.sanchrError)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .alert("Delete all backups?", isPresented: $showDeleteAlert) {
                    Button("Delete", role: .destructive) {
                        Task { await container.backupCoordinator.deleteRemoteBackups() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This cannot be undone.")
                }
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: SanchrSpacing.sm) {
            HStack(spacing: 14) {
                SettingsIconTile(systemName: "shield", role: .accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Backup Active")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    Text(lastBackupSubtitle)
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrSuccess)
                }

                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { container.backupCoordinator.isEnabled },
                        set: { enabled in
                            if !enabled { showDisableAlert = true }
                        }
                    )
                )
                .labelsHidden()
                .tint(.sanchrPrimary)
                .alert("Disable backup?", isPresented: $showDisableAlert) {
                    Button("Disable", role: .destructive) {
                        container.backupCoordinator.disableBackups()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your existing backups will remain on the server until you delete them.")
                }
            }

            if historyState == .loaded {
                let totalBytes = backupHistory.reduce(0) { $0 + $1.byteSize }
                Text("\(backupHistory.count) backup\(backupHistory.count == 1 ? "" : "s") · \(formattedBytes(totalBytes)) stored")
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                    .background(Color.sanchrSurface(colorScheme).opacity(0.6))
                    .clipShape(Capsule())
            }

            Button {
                Task {
                    do {
                        try await container.backupCoordinator.backupNow()
                        await loadHistory()
                    } catch {
                        container.backupCoordinator.reportError(error)
                    }
                }
            } label: {
                HStack(spacing: SanchrSpacing.xs) {
                    if container.backupCoordinator.isProcessing {
                        ProgressView().scaleEffect(0.8)
                    }
                    Text(container.backupCoordinator.isProcessing ? "Backing up…" : "Back Up Now")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.sanchrPrimary)
                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.sm))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(container.backupCoordinator.isProcessing)
        }
    }

    // MARK: - Backup History Rows

    @ViewBuilder
    private var backupHistoryRows: some View {
        switch historyState {
        case .idle, .loading:
            HStack {
                ProgressView()
                Text("Loading history…")
                    .font(SanchrTypography.caption)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            }
        case .failed:
            VStack(spacing: 12) {
                Text("Could not load history")
                    .font(SanchrTypography.caption)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                if let error = lastLoadError {
                    Text(error)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                }
            }
        case .loaded:
            if backupHistory.isEmpty {
                Text("No backups yet")
                    .font(SanchrTypography.caption)
                    .foregroundColor(Color.sanchrTextTertiary(colorScheme))
            } else {
                ForEach(backupHistory) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(formattedDate(entry.committedAt))
                                .font(SanchrTypography.body)
                                .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                            Text(historySubtitle(entry))
                                .font(SanchrTypography.captionSmall)
                                .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        }
                        Spacer()
                        Button("Restore") {
                            restoreTargetId = entry.id
                            restoreRecoveryKey = ""
                            showingRestoreSheet = true
                        }
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrPrimary)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Common Rows

    private var restoreRow: some View {
        Button {
            restoreTargetId = nil
            restoreRecoveryKey = ""
            showingRestoreSheet = true
        } label: {
            HStack(spacing: 14) {
                SettingsIconTile(systemName: "arrow.clockwise.circle", size: 36, iconSize: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Restore from Backup")
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    Text(container.backupCoordinator.isEnabled
                        ? "Recover on a new device"
                        : "Bring history to this device")
                        .font(SanchrTypography.caption)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(container.backupCoordinator.isProcessing)
    }

    // MARK: - Backup Preferences

    private var destinationsBinding: Binding<Set<BackupDestination>> {
        Binding(
            get: { container.backupCoordinator.configuration?.destinations ?? [.sanchrCloud] },
            set: { container.backupCoordinator.updatePreferences(destinations: $0) }
        )
    }

    private var frequencyBinding: Binding<BackupFrequency> {
        Binding(
            get: { container.backupCoordinator.configuration?.frequency ?? .daily },
            set: { container.backupCoordinator.updatePreferences(frequency: $0) }
        )
    }

    private var wifiOnlyMediaBinding: Binding<Bool> {
        Binding(
            get: { container.backupCoordinator.configuration?.wifiOnlyMedia ?? true },
            set: { container.backupCoordinator.updatePreferences(wifiOnlyMedia: $0) }
        )
    }

    private func destinationRow(
        icon: String, title: String, subtitle: String, destination: BackupDestination
    ) -> some View {
        Toggle(
            isOn: Binding(
                get: { destinationsBinding.wrappedValue.contains(destination) },
                set: { enabled in
                    var set = destinationsBinding.wrappedValue
                    if enabled { set.insert(destination) } else { set.remove(destination) }
                    destinationsBinding.wrappedValue = set
                }
            )
        ) {
            HStack(spacing: SanchrSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.sanchrPrimary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    Text(subtitle)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
            }
        }
        .tint(.sanchrPrimary)
    }

    private func backupContentRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemName: icon, size: 36, iconSize: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SanchrTypography.body)
                    .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                Text(subtitle)
                    .font(SanchrTypography.captionSmall)
                    .foregroundColor(Color.sanchrTextSecondary(colorScheme))
            }
        }
    }

    // MARK: - Helpers

    private var lastBackupSubtitle: String {
        guard let date = container.backupCoordinator.configuration?.lastBackupAt else {
            return "✓ Up to date"
        }
        let interval = Date().timeIntervalSince(date)
        if interval < 3600 {
            let mins = max(1, Int(interval / 60))
            return "✓ Up to date · \(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "✓ Up to date · \(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "✓ Up to date · \(days)d ago"
        }
    }

    private func formattedDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today, " + date.formatted(date: .omitted, time: .shortened)
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday, " + date.formatted(date: .omitted, time: .shortened)
        } else {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    private func historySubtitle(_ entry: BackupListEntry) -> String {
        var parts: [String] = [formattedBytes(entry.byteSize)]
        if let count = entry.messageCount {
            parts.append("\(count) messages")
        }
        return parts.joined(separator: " · ")
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func loadHistory() async {
        historyState = .loading
        do {
            backupHistory = try await container.backupCoordinator.listBackups()
            historyState = .loaded
            lastLoadError = nil
        } catch {
            lastLoadError = UserFacingError.message(for: error)
            historyState = .failed
        }
    }
}

// MARK: - BackupRecoveryKeySheet

private struct BackupRecoveryKeySheet: View {
    static func grouped(_ key: String) -> String {
        stride(from: 0, to: key.count, by: 4).map { start in
            let lower = key.index(key.startIndex, offsetBy: start)
            let upper = key.index(lower, offsetBy: 4, limitedBy: key.endIndex) ?? key.endIndex
            return String(key[lower..<upper])
        }.joined(separator: " ")
    }

    @Environment(\.colorScheme) private var colorScheme
    let recoveryKey: String
    let displayOnly: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: SanchrSpacing.lg) {
                if !displayOnly {
                    Text("Save this recovery key somewhere secure. You will need it to restore encrypted backups on a new device.")
                        .font(SanchrTypography.body)
                }

                // Grouped display: broken into short chunks with real spaces so
                // the renderer never hyphenates the key mid-group — a wrapped
                // display once showed phantom hyphens that users then typed
                // back in as part of the key.
                Text(Self.grouped(recoveryKey))
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sanchrSurface(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.md))

                if !displayOnly {
                    Button("I saved this key", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .tint(.sanchrPrimary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Button("Not now", role: .cancel, action: onCancel)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Button("Close", role: .cancel, action: onCancel)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Spacer()
            }
            .padding(SanchrSpacing.lg)
            .sanchrSettingsSubscreenNavigation(title: "Recovery Key")
        }
    }
}

// MARK: - BackupRestoreSheet

private struct BackupRestoreSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var recoveryKey: String
    let backupId: String?
    let isProcessing: Bool
    let onRestore: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: SanchrSpacing.lg) {
                Text("Restore your encrypted chat history after sign-in using your recovery key. If this device already stores the key, you can leave the field blank.")
                    .font(SanchrTypography.body)

                TextField("Recovery key", text: $recoveryKey, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .background(Color.sanchrSurface(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.md))

                Button(
                    backupId != nil ? "Restore This Backup" : "Restore Latest Backup",
                    action: onRestore
                )
                .buttonStyle(.borderedProminent)
                .tint(.sanchrPrimary)
                .disabled(isProcessing)
                .frame(maxWidth: .infinity, alignment: .center)

                Button("Cancel", role: .cancel, action: onCancel)
                    .frame(maxWidth: .infinity, alignment: .center)

                Spacer()
            }
            .padding(SanchrSpacing.lg)
            .sanchrSettingsSubscreenNavigation(title: "Restore Backup")
        }
    }
}

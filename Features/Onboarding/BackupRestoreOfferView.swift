import SanchrShared
import SwiftUI

/// Post-install restore offer. Shown once after signing in on a fresh install
/// when a backup exists on Sanchr Cloud and/or in the user's iCloud. Lets the
/// user pick a source, enter the recovery key, and watch a staged restore.
struct BackupRestoreOfferView: View {
    let sources: BackupRestoreSources
    let onFinished: (_ restored: Bool) -> Void

    @Environment(DependencyContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme

    private enum Source: Hashable {
        case sanchrCloud
        case iCloud
    }

    private enum Stage: Int, CaseIterable {
        case unlock
        case transfer
        case rebuild

        var title: String {
            switch self {
            case .unlock: "Unlocking with your recovery key"
            case .transfer: "Downloading & decrypting your backup"
            case .rebuild: "Rebuilding your chats"
            }
        }
    }

    @State private var selectedSource: Source = .sanchrCloud
    @State private var recoveryKey = ""
    @State private var isRestoring = false
    @State private var currentStage: Stage = .unlock
    @State private var completed = false
    @State private var failureMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    SanchrColors.primaryDark.opacity(0.10),
                    SanchrColors.primary.opacity(0.04),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(Color.sanchrBackground(colorScheme))
            .ignoresSafeArea()

            if isRestoring || completed {
                restoreProgress
            } else {
                offer
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Offer

    private var offer: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: SanchrSpacing.lg) {
                VStack(spacing: SanchrSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [SanchrColors.primaryDark, SanchrColors.primary],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 84, height: 84)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.top, SanchrSpacing.xl)

                    Text("Restore your chats")
                        .font(SanchrTypography.scaled(size: 26, weight: .bold))
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))

                    Text("We found an encrypted backup for this number. Restore it now to bring your history back — this is the only moment it can be restored.")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, SanchrSpacing.md)
                }

                VStack(spacing: SanchrSpacing.sm) {
                    if let server = sources.sanchrCloud {
                        sourceCard(
                            source: .sanchrCloud,
                            icon: "externaldrive.badge.icloud",
                            title: "Sanchr Cloud",
                            detail: sourceDetail(
                                date: server.committedAt,
                                bytes: server.byteSize,
                                messages: server.messageCount
                            )
                        )
                    }
                    if let iCloud = sources.iCloud {
                        sourceCard(
                            source: .iCloud,
                            icon: "icloud",
                            title: "iCloud",
                            detail: sourceDetail(
                                date: iCloud.exportedAt ?? iCloud.entry.modifiedAt,
                                bytes: iCloud.entry.byteSize,
                                messages: iCloud.messageCount
                            )
                        )
                    }
                }

                VStack(alignment: .leading, spacing: SanchrSpacing.xs) {
                    Text("RECOVERY KEY")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    TextField("Enter your recovery key", text: $recoveryKey, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(SanchrSpacing.sm)
                        .background(Color.sanchrSurface(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.md))
                    Text("The key you saved when you enabled backups. Without it the backup cannot be decrypted.")
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                }

                if let failureMessage {
                    Text(failureMessage)
                        .font(SanchrTypography.caption)
                        .foregroundColor(.sanchrError)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: SanchrSpacing.sm) {
                    Button {
                        Task { await restore() }
                    } label: {
                        Text("Restore Backup")
                            .font(SanchrTypography.bodyBold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.sanchrPrimary.opacity(0.4) : Color.sanchrPrimary
                            )
                            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.md))
                    }
                    .buttonStyle(.plain)
                    .disabled(recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        onFinished(false)
                    } label: {
                        Text("Set Up Without Restoring")
                            .font(SanchrTypography.body)
                            .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, SanchrSpacing.lg)
                }
            }
            .padding(.horizontal, SanchrSpacing.lg)
        }
        .onAppear {
            // Preselect the only available source.
            if sources.sanchrCloud == nil, sources.iCloud != nil {
                selectedSource = .iCloud
            }
        }
    }

    private func sourceCard(
        source: Source, icon: String, title: String, detail: String
    ) -> some View {
        Button {
            selectedSource = source
        } label: {
            HStack(spacing: SanchrSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(.sanchrPrimary)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SanchrTypography.bodyBold)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                    Text(detail)
                        .font(SanchrTypography.captionSmall)
                        .foregroundColor(Color.sanchrTextSecondary(colorScheme))
                }
                Spacer()
                Image(
                    systemName: selectedSource == source
                        ? "checkmark.circle.fill" : "circle"
                )
                .font(SanchrTypography.scaled(size: 22, weight: .regular))
                .foregroundColor(
                    selectedSource == source
                        ? .sanchrPrimary : Color.sanchrTextTertiary(colorScheme))
            }
            .padding(SanchrSpacing.md)
            .background(Color.sanchrSurface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: SanchrRadius.lg)
                    .stroke(
                        selectedSource == source ? Color.sanchrPrimary : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func sourceDetail(date: Date?, bytes: Int64, messages: Int?) -> String {
        var parts: [String] = []
        if let date {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if bytes > 0 {
            parts.append(
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if let messages {
            parts.append("\(messages) message\(messages == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Encrypted backup" : parts.joined(separator: " · ")
    }

    // MARK: - Progress

    private var restoreProgress: some View {
        VStack(spacing: SanchrSpacing.xl) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(SanchrColors.primary.opacity(0.15), lineWidth: 6)
                    .frame(width: 96, height: 96)
                if completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 96, weight: .regular))
                        .foregroundColor(.sanchrPrimary)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.sanchrPrimary)
                }
            }

            Text(completed ? "All set!" : "Restoring your chats")
                .font(SanchrTypography.font(size: .xl, weight: .bold))
                .foregroundColor(Color.sanchrTextPrimary(colorScheme))

            VStack(alignment: .leading, spacing: SanchrSpacing.md) {
                ForEach(Stage.allCases, id: \.rawValue) { stage in
                    HStack(spacing: SanchrSpacing.sm) {
                        if completed || stage.rawValue < currentStage.rawValue {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.sanchrPrimary)
                        } else if stage == currentStage {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.sanchrPrimary)
                        } else {
                            Image(systemName: "circle")
                                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
                        }
                        Text(stage.title)
                            .font(SanchrTypography.body)
                            .foregroundColor(
                                stage.rawValue <= currentStage.rawValue || completed
                                    ? Color.sanchrTextPrimary(colorScheme)
                                    : Color.sanchrTextTertiary(colorScheme))
                    }
                }
            }
            .padding(SanchrSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.sanchrSurface(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.lg))
            .padding(.horizontal, SanchrSpacing.lg)

            Text("Keep Sanchr open while your history is restored.")
                .font(SanchrTypography.captionSmall)
                .foregroundColor(Color.sanchrTextSecondary(colorScheme))

            Spacer()
        }
        .animation(.easeInOut(duration: 0.25), value: currentStage)
        .animation(.spring(duration: 0.4), value: completed)
    }

    // MARK: - Restore

    private func restore() async {
        failureMessage = nil
        isRestoring = true
        currentStage = .unlock
        let key = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Brief beat on the key stage so the stepper reads as real progress
        // rather than flashing straight past it.
        try? await Task.sleep(for: .milliseconds(500))
        currentStage = .transfer

        switch selectedSource {
        case .sanchrCloud:
            await container.backupCoordinator.restoreLatestBackup(with: key)
        case .iCloud:
            await container.backupCoordinator.restoreFromICloud(with: key)
        }

        if let error = container.backupCoordinator.errorMessage, !error.isEmpty {
            isRestoring = false
            failureMessage = error
            return
        }

        currentStage = .rebuild
        try? await Task.sleep(for: .milliseconds(600))
        completed = true
        try? await Task.sleep(for: .seconds(1.2))
        onFinished(true)
    }
}

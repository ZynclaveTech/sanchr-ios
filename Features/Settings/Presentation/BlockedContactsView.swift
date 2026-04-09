import SwiftUI
import SanchrShared

/// Sub-screen showing the list of blocked contacts with unblock actions.
struct BlockedContactsView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var blockedIDs: [String] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
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
        .sanchrSettingsSubscreenNavigation(title: "Blocked Contacts")
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

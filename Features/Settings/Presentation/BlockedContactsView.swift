import SwiftUI
import SanchrShared

/// Sub-screen showing the list of blocked contacts with unblock actions.
struct BlockedContactsView: View {
    @Environment(DependencyContainer.self) private var container
    @State private var blockedIDs: [String] = []
    /// Display name (or phone number) per blocked user id, resolved from the
    /// local contact table so the list is readable.
    @State private var blockedNames: [String: String] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                if isLoading {
                    ProgressView()
                        .tint(.sanchrPrimary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if blockedIDs.isEmpty {
                    VStack(spacing: 12) {
                        SettingsIconTile(systemName: "hand.raised.slash", size: 72, iconSize: 24)
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
                                SettingsIconTile(systemName: "person", role: .destructive)

                                Text(displayName(for: userId))
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
                        }
                    }
                    .padding(.horizontal, SanchrExportMetrics.sectionHorizontal)
                    .padding(.bottom, 28)
                }
            }
        }
        .sanchrSettingsSubscreenNavigation(title: "Blocked Contacts")
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await loadBlocked()
        }
    }

    /// A blocked entry is only actionable if the user can tell who it is. The
    /// server returns ids alone, so names come from the local contact table —
    /// the same source the conversation list reads — falling back to the phone
    /// number and finally to a shortened id when the person was never resolved.
    private func displayName(for userId: String) -> String {
        blockedNames[userId] ?? shortID(userId)
    }

    private func resolveNames(for ids: [String]) async {
        guard !ids.isEmpty,
            let contacts = try? await container.localDatabase.fetchContacts()
        else { return }
        let lookup = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        var resolved: [String: String] = [:]
        for id in ids {
            guard let contact = lookup[id] else { continue }
            let name = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty,
                name != User.serverPlaceholderDisplayName,
                name != id,
                UUID(uuidString: name) == nil
            {
                resolved[id] = name
            } else if !contact.phoneNumber.isEmpty {
                resolved[id] = contact.phoneNumber
            }
        }
        blockedNames = resolved
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
            await resolveNames(for: blockedIDs)
        } catch {
            errorMessage = error.localizedDescription
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
            container.privacySettings.setBlocked(userId, false)
            blockedIDs.removeAll { $0 == userId }
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.sync.error("Failed to unblock: \(error.localizedDescription)")
        }
    }
}

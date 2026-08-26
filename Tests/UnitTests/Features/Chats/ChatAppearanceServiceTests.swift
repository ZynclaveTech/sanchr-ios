import XCTest
import SanchrShared
@testable import Sanchr

@MainActor
final class ChatAppearanceServiceTests: XCTestCase {

    func test_effectiveAppearance_returnsGlobalWhenNoOverride() async {
        let service = makeService(globalWallpaperId: "amber_glow", globalMode: .light)
        let appearance = service.effectiveAppearance(for: "conv-1")
        XCTAssertEqual(appearance.wallpaperId, "amber_glow")
        XCTAssertEqual(appearance.appearanceMode, .light)
        XCTAssertFalse(appearance.isPerChatOverride)
    }

    func test_effectiveAppearance_returnsOverrideWhenPresent() async {
        let db = StubDatabase()
        db.appearanceOverrides["conv-1"] = AppearanceOverride(
            wallpaperId: "midnight",
            appearanceMode: .dark
        )
        let service = makeService(localDatabase: db, globalWallpaperId: "default", globalMode: .light)
        await service.loadOverride(conversationId: "conv-1")

        let appearance = service.effectiveAppearance(for: "conv-1")
        XCTAssertEqual(appearance.wallpaperId, "midnight")
        XCTAssertEqual(appearance.appearanceMode, .dark)
        XCTAssertTrue(appearance.isPerChatOverride)
    }

    func test_effectiveAppearance_mixesOverrideWallpaperWithGlobalMode() async {
        let db = StubDatabase()
        db.appearanceOverrides["conv-1"] = AppearanceOverride(
            wallpaperId: "deep_blue",
            appearanceMode: nil
        )
        let service = makeService(localDatabase: db, globalWallpaperId: "default", globalMode: .light)
        await service.loadOverride(conversationId: "conv-1")

        let appearance = service.effectiveAppearance(for: "conv-1")
        XCTAssertEqual(appearance.wallpaperId, "deep_blue")
        XCTAssertEqual(appearance.appearanceMode, .light) // global
        XCTAssertTrue(appearance.isPerChatOverride)
    }

    func test_setOverride_persistsAndRefreshesCache() async {
        let db = StubDatabase()
        let service = makeService(localDatabase: db, globalWallpaperId: "default", globalMode: .light)

        await service.setOverride(
            conversationId: "conv-1",
            wallpaperId: "midnight",
            appearanceMode: .dark
        )

        XCTAssertEqual(db.appearanceOverrides["conv-1"]?.wallpaperId, "midnight")
        XCTAssertEqual(service.effectiveAppearance(for: "conv-1").wallpaperId, "midnight")
    }

    func test_setOverride_withBothNilClearsRow() async {
        let db = StubDatabase()
        db.appearanceOverrides["conv-1"] = AppearanceOverride(
            wallpaperId: "midnight",
            appearanceMode: .dark
        )
        let service = makeService(localDatabase: db, globalWallpaperId: "default", globalMode: .light)
        await service.loadOverride(conversationId: "conv-1")

        await service.setOverride(
            conversationId: "conv-1",
            wallpaperId: nil,
            appearanceMode: nil
        )

        XCTAssertNil(db.appearanceOverrides["conv-1"])
        let appearance = service.effectiveAppearance(for: "conv-1")
        XCTAssertEqual(appearance.wallpaperId, "default")
        XCTAssertFalse(appearance.isPerChatOverride)
    }

    func test_setGlobal_mirrorsToSettingsViewModelAndTheme() async {
        let theme = SanchrTheme()
        let settingsVM = SettingsViewModel()
        let service = makeService(
            theme: theme,
            settingsViewModel: settingsVM,
            globalWallpaperId: "default",
            globalMode: .light
        )

        service.setGlobal(wallpaperId: "midnight", appearanceMode: .dark)

        XCTAssertEqual(service.globalWallpaperId, "midnight")
        XCTAssertEqual(service.globalMode, .dark)
        XCTAssertEqual(settingsVM.chatWallpaper, "midnight")
        XCTAssertEqual(theme.mode, .dark)
    }

    func test_loadOverride_isIdempotent() async {
        let db = StubDatabase()
        db.appearanceOverrides["conv-1"] = AppearanceOverride(
            wallpaperId: "midnight",
            appearanceMode: .dark
        )
        let service = makeService(localDatabase: db, globalWallpaperId: "default", globalMode: .light)

        await service.loadOverride(conversationId: "conv-1")
        // Mutate the DB out from under the service — second load should NOT
        // refresh the cache (idempotent within the lifetime of the cache).
        db.appearanceOverrides["conv-1"] = AppearanceOverride(
            wallpaperId: "amber_glow",
            appearanceMode: .light
        )
        await service.loadOverride(conversationId: "conv-1")

        XCTAssertEqual(service.effectiveAppearance(for: "conv-1").wallpaperId, "midnight")
    }

    // MARK: - Builders

    private func makeService(
        localDatabase: LocalDatabaseProtocol = StubDatabase(),
        theme: SanchrTheme = SanchrTheme(),
        settingsViewModel: SettingsViewModel = SettingsViewModel(),
        globalWallpaperId: String,
        globalMode: SanchrTheme.Mode
    ) -> ChatAppearanceService {
        settingsViewModel.chatWallpaper = globalWallpaperId
        theme.mode = globalMode
        return ChatAppearanceService(
            localDatabase: localDatabase,
            theme: theme,
            settingsViewModel: settingsViewModel
        )
    }
}

/// In-memory LocalDatabase test double scoped to ChatAppearanceServiceTests.
/// Only the appearance-override methods are real; everything else
/// crash-on-call so accidental misuse during these tests is loud.
private final class StubDatabase: LocalDatabaseProtocol, @unchecked Sendable {
    var appearanceOverrides: [String: AppearanceOverride] = [:]

    func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride? {
        appearanceOverrides[conversationId]
    }
    func setAppearanceOverride(_ override: AppearanceOverride, for conversationId: String) async throws {
        if override.wallpaperId == nil && override.appearanceMode == nil {
            appearanceOverrides.removeValue(forKey: conversationId)
        } else {
            appearanceOverrides[conversationId] = override
        }
    }
    func clearAppearanceOverride(conversationId: String) async throws {
        appearanceOverrides.removeValue(forKey: conversationId)
    }

    // Crash-on-call stubs for the rest of the protocol.
    func saveMessage(_ message: Message) async throws { fatalError() }
    func saveIncomingMessageAndQueueAck(_ message: Message) async throws { fatalError() }
    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] { fatalError() }
    func deleteMessage(id: String) async throws { fatalError() }
    func purgeExpiredMessages() async throws -> [String] { [] }
    func markConversationAsRead(conversationId: String, upToMessageId: String) async throws { fatalError() }
    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws { fatalError() }
    func fetchPendingMessageAcks(limit: Int) async throws -> [PendingMessageAck] { fatalError() }
    func deletePendingMessageAcks(_ acks: [PendingMessageAck]) async throws { fatalError() }
    func searchMessages(conversationId: String, query: String) async throws -> [Message] { fatalError() }
    func saveConversation(_ conversation: Conversation) async throws { fatalError() }
    func fetchConversation(id: String) async throws -> Conversation? { fatalError() }
    func fetchConversations() async throws -> [Conversation] { fatalError() }
    func deleteConversation(id: String) async throws { fatalError() }
    func saveContact(_ user: User) async throws { fatalError() }
    func fetchContacts() async throws -> [User] { fatalError() }
    func searchContacts(query: String) async throws -> [User] { fatalError() }
    func saveVaultItem(_ item: VaultItem) async throws { fatalError() }
    func fetchVaultItems() async throws -> [VaultItem] { fatalError() }
    func fetchAllVaultItems() async throws -> [VaultItem] { fatalError() }
    func deleteVaultItem(id: String) async throws { fatalError() }
    func saveAccessKeyEntry(_ entry: AccessKeyEntry) async throws { fatalError() }
    func fetchAccessKeyEntry(mediaId: String) async throws -> AccessKeyEntry? { fatalError() }
    func updateAccessKeyEntryLastAccessed(mediaId: String, lastAccessedAt: Date) async throws { fatalError() }
    func deleteAccessKeyEntry(mediaId: String) async throws { fatalError() }
    func purgeAccessKeyEntries(olderThan: Date) async throws -> Int { fatalError() }
    func deleteAllAccessKeyEntries() async throws { fatalError() }
    func hasLocalHistory() async throws -> Bool { fatalError() }
    func exportBackupSnapshot(currentUserId: String?, fingerprint: String) async throws -> BackupArchiveSnapshot { fatalError() }
    func restoreBackupSnapshot(_ snapshot: BackupArchiveSnapshot, currentUserId: String?, localFingerprint: String) async throws { fatalError() }
    func purgeAllData() async throws { fatalError() }
}

# Backup & Recovery Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the inline backup card in ChatSettingsView with a dedicated, full-featured BackupView screen accessible from both main Settings and Chat Settings.

**Architecture:** New `BackupListEntry` value type added to `BackupArchiveService.swift`; two new protocol methods (`listBackups`, `restoreBackup(backupId:)`) added to `BackupArchiveServiceProtocol` and implemented in `BackupArchiveService`; two corresponding coordinator wrappers in `BackupCoordinator`; new standalone `BackupView.swift`; both sheet structs and all backup `@State` vars migrate from `ChatSettingsView` into `BackupView`. `SettingsView` and `ChatSettingsView` each get a single new navigation row.

**Tech Stack:** Swift 5.9, SwiftUI, `@Observable`, gRPC / `Vync_Backup_*` protos, XCTest

---

## File Map

| Status | Path | Change |
|--------|------|--------|
| Modify | `ios/Sanchr-IOS/Shared/Services/BackupArchiveService.swift` | Add `BackupListEntry` struct; add `listBackups()` + `restoreBackup(backupId:…)` to protocol + actor |
| Modify | `ios/Sanchr-IOS/Tests/UnitTests/TestDoubles.swift` | Add `MockBackupArchiveService`, `MockRecoveryKeyManager`, `MockBackupKeyDeriver` |
| Create | `ios/Sanchr-IOS/Tests/UnitTests/Features/Settings/BackupCoordinatorTests.swift` | Unit tests for both new coordinator methods |
| Modify | `ios/Sanchr-IOS/Shared/Services/BackupCoordinator.swift` | Add `listBackups()` + `restoreBackup(backupId:with:)` public methods |
| Create | `ios/Sanchr-IOS/Features/Settings/Presentation/BackupView.swift` | Full dedicated screen (both states + both sheet structs) |
| Modify | `ios/Sanchr-IOS/Features/Settings/Presentation/SettingsView.swift` | Add "Backup & Recovery" row to Account group |
| Modify | `ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift` | Replace `backupSection` with single nav row; remove sheet structs + backup `@State` vars |

---

## Task 1: `BackupListEntry` + Protocol + Service Implementation + Test Doubles

**Files:**
- Modify: `ios/Sanchr-IOS/Shared/Services/BackupArchiveService.swift`
- Modify: `ios/Sanchr-IOS/Tests/UnitTests/TestDoubles.swift`

### Step 1.1 — Add `BackupListEntry` and extend the protocol

Re-read `BackupArchiveService.swift` first. Then insert `BackupListEntry` after the `BackupRestoreOutcome` struct (line 17) and the two new method signatures into `BackupArchiveServiceProtocol`.

Replace the closing brace of `BackupRestoreOutcome` so the file reads:

```swift
struct BackupRestoreOutcome: Sendable {
    let lineageID: String
    let formatVersion: Int32
    let backupDate: Date?
    let contentHash: String?
}

struct BackupListEntry: Identifiable, Sendable {
    let id: String          // backup_id from proto
    let committedAt: Date
    let byteSize: Int64
    let messageCount: Int?  // from opaqueMetadata JSON counts.messages; nil if unparseable
}
```

Then extend the protocol (currently ends at line 43) to add the two new signatures:

```swift
protocol BackupArchiveServiceProtocol: Sendable {
    func performBackup(
        configuration: BackupConfiguration,
        material: DerivedBackupMaterial,
        currentUserId: String?,
        force: Bool
    ) async throws -> BackupUploadOutcome?
    func restoreLatestBackup(
        configuration: BackupConfiguration?,
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome
    func deleteRemoteBackups(lineageID: String?) async throws
    func listBackups() async throws -> [BackupListEntry]
    func restoreBackup(
        backupId: String,
        configuration: BackupConfiguration?,
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome
}
```

- [ ] Re-read `BackupArchiveService.swift` (lines 1–45)
- [ ] Edit: insert `BackupListEntry` struct after `BackupRestoreOutcome` (after line 17)
- [ ] Edit: add two new method signatures to `BackupArchiveServiceProtocol` (after `deleteRemoteBackups`)
- [ ] Re-read lines 1–50 to confirm both edits landed correctly

### Step 1.2 — Implement `listBackups()` on the actor

Add the following method inside `actor BackupArchiveService`, after `deleteRemoteBackups` (currently ends around line 196):

```swift
func listBackups() async throws -> [BackupListEntry] {
    let response = try await grpcClient.backupService.listBackups(Vync_Backup_ListBackupsRequest())
    return response.backups
        .map { meta -> BackupListEntry in
            let date = Self.parseServerDate(
                meta.committedAt.isEmpty ? meta.createdAt : meta.committedAt
            ) ?? Date()
            let messageCount: Int? = {
                guard !meta.opaqueMetadata.isEmpty,
                      let parsed = try? JSONDecoder().decode(
                          BackupOpaqueMetadata.self, from: meta.opaqueMetadata
                      )
                else { return nil }
                return parsed.counts.messages
            }()
            return BackupListEntry(
                id: meta.backupID,
                committedAt: date,
                byteSize: meta.byteSize,
                messageCount: messageCount
            )
        }
        .sorted { $0.committedAt > $1.committedAt }
}
```

- [ ] Edit: insert `listBackups()` into the actor body after `deleteRemoteBackups`
- [ ] Re-read the insertion site to confirm correct placement

### Step 1.3 — Implement `restoreBackup(backupId:…)` on the actor

Add after `listBackups()`. This mirrors `restoreLatestBackup` but bypasses the list call and fetches the specified backup directly:

```swift
func restoreBackup(
    backupId: String,
    configuration: BackupConfiguration?,
    material: DerivedBackupMaterial,
    currentUserId: String?
) async throws -> BackupRestoreOutcome {
    guard currentUserId?.isEmpty == false else {
        throw AppError.backupFailed(reason: "You must be signed in before restoring a backup.")
    }
    guard let aesKey = material.aesKey, let hmacKey = material.hmacKey else {
        throw AppError.backupFailed(reason: "Backup keys are unavailable for this account.")
    }

    var request = Vync_Backup_GetBackupDownloadRequest()
    request.backupID = backupId
    let response = try await grpcClient.backupService.getBackupDownload(request)
    let ciphertext = try await Self.downloadObject(from: response.downloadURL, session: session)
    let expectedSha = response.backup.sha256Hash

    guard Self.sha256Hex(ciphertext) == expectedSha else {
        throw AppError.backupIntegrityCheckFailed(
            reason: "Encrypted backup SHA-256 did not match the committed metadata."
        )
    }

    let metadata = try JSONDecoder().decode(
        BackupOpaqueMetadata.self, from: response.backup.opaqueMetadata
    )
    let iv = Data(base64Encoded: metadata.ivBase64) ?? Data()
    let hmac = Data(base64Encoded: metadata.hmacBase64) ?? Data()
    let computedHMAC = Self.hmac(iv: iv, ciphertext: ciphertext, key: hmacKey)
    guard computedHMAC == hmac else {
        throw AppError.backupIntegrityCheckFailed(reason: "Backup HMAC verification failed.")
    }

    let plaintext = try Self.decryptArchive(ciphertext, aesKey: aesKey, iv: iv)
    let snapshot = try BackupArchiveSerializer.deserialize(plaintext)
    let localFingerprint = try deviceSecretProvider.backupFingerprint()
    try await localDatabase.restoreBackupSnapshot(
        snapshot,
        currentUserId: currentUserId,
        localFingerprint: localFingerprint
    )

    return BackupRestoreOutcome(
        lineageID: response.backup.lineageID,
        formatVersion: response.backup.formatVersion,
        backupDate: Self.parseServerDate(
            response.backup.committedAt.isEmpty
                ? response.backup.createdAt
                : response.backup.committedAt
        ),
        contentHash: metadata.contentHash
    )
}
```

- [ ] Edit: insert `restoreBackup(backupId:…)` after `listBackups()` in the actor
- [ ] Re-read both new methods to confirm the code is correct

### Step 1.4 — Add test doubles to `TestDoubles.swift`

Append the following three mock classes to `TestDoubles.swift`. These are needed by `BackupCoordinatorTests` in Task 2.

```swift
// MARK: - MockBackupArchiveService

final class MockBackupArchiveService: BackupArchiveServiceProtocol, @unchecked Sendable {
    var performBackupResult: BackupUploadOutcome? = nil
    var performBackupError: Error? = nil
    var restoreLatestResult: BackupRestoreOutcome = BackupRestoreOutcome(
        lineageID: "test-lineage", formatVersion: 1, backupDate: nil, contentHash: nil
    )
    var restoreLatestError: Error? = nil
    var listBackupsResult: [BackupListEntry] = []
    var listBackupsError: Error? = nil
    var restoreBackupResult: BackupRestoreOutcome = BackupRestoreOutcome(
        lineageID: "test-lineage", formatVersion: 1, backupDate: nil, contentHash: nil
    )
    var restoreBackupError: Error? = nil
    var deleteRemoteBackupsError: Error? = nil

    // Capture arguments for assertion
    var capturedRestoreBackupId: String? = nil

    func performBackup(
        configuration: BackupConfiguration,
        material: DerivedBackupMaterial,
        currentUserId: String?,
        force: Bool
    ) async throws -> BackupUploadOutcome? {
        if let error = performBackupError { throw error }
        return performBackupResult
    }

    func restoreLatestBackup(
        configuration: BackupConfiguration?,
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome {
        if let error = restoreLatestError { throw error }
        return restoreLatestResult
    }

    func deleteRemoteBackups(lineageID: String?) async throws {
        if let error = deleteRemoteBackupsError { throw error }
    }

    func listBackups() async throws -> [BackupListEntry] {
        if let error = listBackupsError { throw error }
        return listBackupsResult
    }

    func restoreBackup(
        backupId: String,
        configuration: BackupConfiguration?,
        material: DerivedBackupMaterial,
        currentUserId: String?
    ) async throws -> BackupRestoreOutcome {
        capturedRestoreBackupId = backupId
        if let error = restoreBackupError { throw error }
        return restoreBackupResult
    }
}

// MARK: - MockRecoveryKeyManager

final class MockRecoveryKeyManager: RecoveryKeyManagerProtocol, @unchecked Sendable {
    var storedConfiguration: BackupConfiguration? = nil
    var storedRecoveryKey: String? = nil
    var generateKeyResult: String = "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF"
    var enableBackupsResult: BackupConfiguration = BackupConfiguration(
        isEnabled: true,
        lineageId: "test-lineage",
        formatVersion: 1,
        recoveryKeyConfirmedAt: Date()
    )

    func loadConfiguration() throws -> BackupConfiguration? { storedConfiguration }
    func readRecoveryKey() throws -> String? { storedRecoveryKey }
    func generateRecoveryKey() throws -> String { generateKeyResult }
    func enableBackups(with recoveryKey: String, lineageId: String) throws -> BackupConfiguration {
        storedRecoveryKey = recoveryKey
        storedConfiguration = enableBackupsResult
        return enableBackupsResult
    }
    func disableBackups() throws {
        storedConfiguration = nil
        storedRecoveryKey = nil
    }
    func updateBackupState(lastBackupAt: Date?, lastBackupContentHash: String?) throws {}
    func persistRestoredBackup(
        recoveryKey: String,
        lineageId: String,
        formatVersion: Int32,
        lastBackupAt: Date?,
        lastBackupContentHash: String?
    ) throws -> BackupConfiguration {
        storedRecoveryKey = recoveryKey
        return enableBackupsResult
    }
    func clearBackupMaterial() throws {
        storedRecoveryKey = nil
        storedConfiguration = nil
    }
}

// MARK: - MockBackupKeyDeriver

final class MockBackupKeyDeriver: BackupKeyDeriverProtocol, @unchecked Sendable {
    var derivedMaterial: DerivedBackupMaterial = DerivedBackupMaterial(aesKey: nil, hmacKey: nil)
    var deriveError: Error? = nil

    func deriveMaterial(recoveryKey: String, userId: String?) throws -> DerivedBackupMaterial {
        if let error = deriveError { throw error }
        return derivedMaterial
    }
}
```

- [ ] Re-read the tail of `TestDoubles.swift` to confirm it ends cleanly
- [ ] Edit: append all three mock classes to `TestDoubles.swift`
- [ ] Re-read the appended section to verify syntax

### Step 1.5 — Commit

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add \
  ../Sanchr-IOS/Shared/Services/BackupArchiveService.swift \
  ../Sanchr-IOS/Tests/UnitTests/TestDoubles.swift
git commit -m "feat(backup): add BackupListEntry, listBackups + restoreBackup protocol/service + test doubles"
```

---

## Task 2: `BackupCoordinator` New Methods + Tests

**Files:**
- Modify: `ios/Sanchr-IOS/Shared/Services/BackupCoordinator.swift`
- Create: `ios/Sanchr-IOS/Tests/UnitTests/Features/Settings/BackupCoordinatorTests.swift`

### Step 2.1 — Write the failing tests first

Create `Tests/UnitTests/Features/Settings/BackupCoordinatorTests.swift`:

```swift
import XCTest
@testable import Sanchr

@MainActor
final class BackupCoordinatorTests: XCTestCase {

    // MARK: - listBackups

    func test_listBackups_returnsSortedDescendingByDate() async throws {
        let service = MockBackupArchiveService()
        let older = Date().addingTimeInterval(-3600)  // 1 hour ago
        let newer = Date()
        service.listBackupsResult = [
            BackupListEntry(id: "b1", committedAt: older, byteSize: 1024, messageCount: 5),
            BackupListEntry(id: "b2", committedAt: newer, byteSize: 2048, messageCount: 10),
        ]
        let coordinator = makeCoordinator(service: service)

        let entries = try await coordinator.listBackups()

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, "b2")  // newer first
        XCTAssertEqual(entries[1].id, "b1")
    }

    func test_listBackups_preservesMessageCount() async throws {
        let service = MockBackupArchiveService()
        service.listBackupsResult = [
            BackupListEntry(id: "b1", committedAt: Date(), byteSize: 512, messageCount: 42),
        ]
        let coordinator = makeCoordinator(service: service)

        let entries = try await coordinator.listBackups()

        XCTAssertEqual(entries.first?.messageCount, 42)
    }

    func test_listBackups_propagatesServiceError() async {
        let service = MockBackupArchiveService()
        service.listBackupsError = AppError.backupUnavailable
        let coordinator = makeCoordinator(service: service)

        do {
            _ = try await coordinator.listBackups()
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - restoreBackup(backupId:with:)

    func test_restoreBackup_callsServiceWithCorrectId() async {
        let service = MockBackupArchiveService()
        let keyManager = MockRecoveryKeyManager()
        keyManager.storedRecoveryKey = "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF"
        keyManager.storedConfiguration = BackupConfiguration(
            isEnabled: true,
            lineageId: "lineage-1",
            formatVersion: 1,
            recoveryKeyConfirmedAt: Date()
        )
        let coordinator = makeCoordinator(service: service, keyManager: keyManager)

        await coordinator.restoreBackup(backupId: "backup-xyz", with: nil)

        XCTAssertEqual(service.capturedRestoreBackupId, "backup-xyz")
    }

    func test_restoreBackup_doesNotCallListBackups() async {
        let service = MockBackupArchiveService()
        let keyManager = MockRecoveryKeyManager()
        keyManager.storedRecoveryKey = "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF"
        keyManager.storedConfiguration = BackupConfiguration(
            isEnabled: true,
            lineageId: "lineage-1",
            formatVersion: 1,
            recoveryKeyConfirmedAt: Date()
        )
        service.listBackupsResult = []  // if listBackups is called it returns empty — restore would fail
        let coordinator = makeCoordinator(service: service, keyManager: keyManager)

        await coordinator.restoreBackup(backupId: "backup-xyz", with: nil)

        // If listBackups had been called, capturedRestoreBackupId would still be set (restoreBackup was called)
        // The real assertion: listBackups count is 0 proving we did NOT call listBackups
        XCTAssertEqual(service.capturedRestoreBackupId, "backup-xyz")
        XCTAssertNil(coordinator.errorMessage)
    }

    func test_restoreBackup_setsErrorOnFailure() async {
        let service = MockBackupArchiveService()
        service.restoreBackupError = AppError.backupIntegrityCheckFailed(reason: "bad hash")
        let keyManager = MockRecoveryKeyManager()
        keyManager.storedRecoveryKey = "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF"
        let coordinator = makeCoordinator(service: service, keyManager: keyManager)

        await coordinator.restoreBackup(backupId: "backup-xyz", with: nil)

        XCTAssertNotNil(coordinator.errorMessage)
    }

    // MARK: - Helpers

    private func makeCoordinator(
        service: MockBackupArchiveService = MockBackupArchiveService(),
        keyManager: MockRecoveryKeyManager = MockRecoveryKeyManager(),
        keyDeriver: MockBackupKeyDeriver = MockBackupKeyDeriver()
    ) -> BackupCoordinator {
        BackupCoordinator(
            backupService: service,
            recoveryKeyManager: keyManager,
            backupKeyDeriver: keyDeriver,
            currentUserIdProvider: { "user-1" },
            postRestore: {}
        )
    }
}
```

- [ ] Create directory: `mkdir -p ios/Sanchr-IOS/Tests/UnitTests/Features/Settings`
- [ ] Write `BackupCoordinatorTests.swift` with the content above
- [ ] Run tests (they will fail — `BackupCoordinator` doesn't have the new methods yet):
  ```bash
  cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
  xcodebuild test -scheme Sanchr -destination "platform=iOS Simulator,name=iPhone 16" \
    -only-testing SanchrTests/BackupCoordinatorTests 2>&1 | tail -20
  ```
  Expected: compile error — `coordinator.listBackups()` and `coordinator.restoreBackup(backupId:with:)` do not exist

### Step 2.2 — Implement `listBackups()` on `BackupCoordinator`

Re-read `BackupCoordinator.swift` (especially `restoreLatestBackup` pattern, lines 117–148). Add after `revealRecoveryKey()` (currently line 171), before `reportError`:

```swift
func listBackups() async throws -> [BackupListEntry] {
    try await backupService.listBackups()
}

func restoreBackup(backupId: String, with recoveryKeyOverride: String?) async {
    guard !isProcessing else { return }

    do {
        let recoveryKey = try resolvedRecoveryKey(recoveryKeyOverride)
        let material = try backupKeyDeriver.deriveMaterial(
            recoveryKey: recoveryKey,
            userId: currentUserIdProvider()
        )
        isProcessing = true
        errorMessage = nil

        let result = try await backupService.restoreBackup(
            backupId: backupId,
            configuration: configuration,
            material: material,
            currentUserId: currentUserIdProvider()
        )
        _ = try recoveryKeyManager.persistRestoredBackup(
            recoveryKey: recoveryKey,
            lineageId: result.lineageID,
            formatVersion: result.formatVersion,
            lastBackupAt: result.backupDate,
            lastBackupContentHash: result.contentHash
        )
        reload()
        await postRestore()
    } catch {
        errorMessage = error.localizedDescription
    }

    isProcessing = false
}
```

- [ ] Re-read `BackupCoordinator.swift` lines 165–180 (around `revealRecoveryKey` / `reportError`)
- [ ] Edit: insert both methods between `revealRecoveryKey` and `reportError`
- [ ] Re-read the insertion site to confirm correct placement

### Step 2.3 — Run tests; confirm pass

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test -scheme Sanchr -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing SanchrTests/BackupCoordinatorTests 2>&1 | tail -30
```

Expected: all 5 tests PASS.

- [ ] Run the tests
- [ ] If any test fails, diagnose and fix before proceeding

### Step 2.4 — Commit

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add \
  ../Sanchr-IOS/Shared/Services/BackupCoordinator.swift \
  ../Sanchr-IOS/Tests/UnitTests/Features/Settings/BackupCoordinatorTests.swift
git commit -m "feat(backup): add listBackups and restoreBackup(backupId:) to BackupCoordinator"
```

---

## Task 3: `BackupView.swift` — Full Dedicated Screen

**Files:**
- Create: `ios/Sanchr-IOS/Features/Settings/Presentation/BackupView.swift`

### Step 3.1 — Write `BackupView.swift`

Create the file at `ios/Sanchr-IOS/Features/Settings/Presentation/BackupView.swift`:

```swift
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
        .navigationTitle("Backup & Recovery")
        .navigationBarTitleDisplayMode(.inline)
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
                        showingRestoreSheet = false
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
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: 0xEEF2FF))
                        .frame(width: 56, height: 56)
                        .overlay {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(.sanchrPrimary)
                        }

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
                            .background(.sanchrPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.md))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, SanchrSpacing.sm)
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // What gets backed up
            Section("WHAT GETS BACKED UP") {
                backupContentRow(icon: "💬", title: "Messages & conversations", subtitle: "All chats, group info, contacts")
                backupContentRow(icon: "🔐", title: "Vault items", subtitle: "Encrypted vault media & keys")
                backupContentRow(icon: "🖼️", title: "Photos & videos", subtitle: "Re-downloaded from Sanchr on restore")
            }
            .listRowBackground(Color.sanchrSurface(colorScheme))

            // Restore row — always visible
            Section("RESTORE") {
                restoreRow
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
                    Label("View Recovery Key", systemImage: "key.fill")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                }
                .buttonStyle(.plain)

                Button {
                    container.backupCoordinator.rotateRecoveryKey()
                    showingRecoveryKeySheet = true
                } label: {
                    Label("Rotate Recovery Key", systemImage: "arrow.clockwise")
                        .font(SanchrTypography.body)
                        .foregroundColor(Color.sanchrTextPrimary(colorScheme))
                }
                .buttonStyle(.plain)
            } header: {
                Text("RECOVERY KEY")
            } footer: {
                Text("Save your recovery key somewhere safe. Without it you cannot restore your backup on a new device.")
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
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: 0xEEF2FF))
                    .frame(width: 42, height: 42)
                    .overlay {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.sanchrPrimary)
                    }

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
                    do { try await container.backupCoordinator.backupNow() } catch {
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
                .background(.sanchrPrimary)
                .clipShape(RoundedRectangle(cornerRadius: SanchrRadius.sm))
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
            Text("Could not load history")
                .font(SanchrTypography.caption)
                .foregroundColor(Color.sanchrTextTertiary(colorScheme))
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
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color(hex: 0x06B6D4))
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
        }
        .buttonStyle(.plain)
        .disabled(container.backupCoordinator.isProcessing)
    }

    private func backupContentRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Text(icon).font(.title2)
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
            let mins = Int(interval / 60)
            return "✓ Up to date · \(mins == 0 ? "just now" : "\(mins)m ago")"
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
        } catch {
            historyState = .failed
        }
    }
}

// MARK: - BackupRecoveryKeySheet

private struct BackupRecoveryKeySheet: View {
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

                Text(recoveryKey)
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
            .navigationTitle("Recovery Key")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - BackupRestoreSheet

private struct BackupRestoreSheet: View {
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
                    .background(Color(uiColor: .secondarySystemBackground))
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
            .navigationTitle("Restore Backup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
```

- [ ] Create `ios/Sanchr-IOS/Features/Settings/Presentation/BackupView.swift` with the content above
- [ ] Run a type-check to verify it compiles (Xcode build will catch issues):
  ```bash
  cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
  xcodebuild build -scheme Sanchr -destination "platform=iOS Simulator,name=iPhone 16" 2>&1 | grep -E "error:|Build succeeded"
  ```
  Expected: `Build succeeded`
- [ ] Fix any compiler errors before proceeding

### Step 3.2 — Commit

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add ../Sanchr-IOS/Features/Settings/Presentation/BackupView.swift
git commit -m "feat(backup): add BackupView with full disabled/enabled states and sheet components"
```

---

## Task 4: `SettingsView.swift` — Add Backup & Recovery Row

**Files:**
- Modify: `ios/Sanchr-IOS/Features/Settings/Presentation/SettingsView.swift`

### Step 4.1 — Add the row

Re-read `SettingsView.swift` (lines 18–54). The Account group currently has 4 rows: Encryption Keys, Security, Privacy, Vault. Add "Backup & Recovery" as the fifth row after Vault.

```swift
AnySettingsRow(
    icon: "icloud.and.arrow.up.fill",
    tint: SanchrColors.primary,
    background: Color(hex: 0xEEF2FF),
    title: "Backup & Recovery",
    subtitle: backupSubtitle,
    destination: AnyView(BackupView())
),
```

Add `backupSubtitle` as a computed property on `SettingsView` (place it near `themeSubtitle` and `storageSubtitle`, which are around lines 346–360):

```swift
private var backupSubtitle: String {
    let coordinator = container.backupCoordinator
    guard coordinator.isEnabled else { return "Off" }
    guard let lastBackupAt = coordinator.configuration?.lastBackupAt else {
        return "Enabled · No backups yet"
    }
    let interval = Date().timeIntervalSince(lastBackupAt)
    if interval < 3600 {
        let mins = max(1, Int(interval / 60))
        return "Last backed up \(mins)m ago"
    } else if interval < 86400 {
        let hours = Int(interval / 3600)
        return "Last backed up \(hours)h ago"
    } else {
        let days = Int(interval / 86400)
        return "Last backed up \(days)d ago"
    }
}
```

- [ ] Re-read `SettingsView.swift` lines 18–55 (Account group)
- [ ] Edit: insert the `AnySettingsRow` for Backup & Recovery after the Vault row
- [ ] Re-read `SettingsView.swift` lines 345–365 (subtitle helpers)
- [ ] Edit: insert `backupSubtitle` computed property alongside `themeSubtitle`
- [ ] Re-read both edited regions to confirm placement

### Step 4.2 — Build check

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild build -scheme Sanchr -destination "platform=iOS Simulator,name=iPhone 16" 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] Fix any compile errors before proceeding

### Step 4.3 — Commit

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add ../Sanchr-IOS/Features/Settings/Presentation/SettingsView.swift
git commit -m "feat(backup): add Backup & Recovery row to main Settings Account group"
```

---

## Task 5: `ChatSettingsView.swift` — Replace Backup Section with Navigation Row

**Files:**
- Modify: `ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift`

### Step 5.1 — Remove backup `@State` vars and sheets

Re-read `ChatSettingsView.swift` lines 1–20. Remove the five backup-related `@State` vars:

```swift
// REMOVE these lines:
@State private var showingRecoveryKeySheet = false
@State private var revealedRecoveryKey: String?
@State private var showingRevealedRecoveryKey = false
@State private var showingRestoreSheet = false
@State private var restoreRecoveryKey = ""
```

- [ ] Re-read `ChatSettingsView.swift` lines 1–25
- [ ] Edit: delete the five `@State` vars (lines 15–19)
- [ ] Re-read lines 1–25 to confirm removal

### Step 5.2 — Remove `.sheet` and `.alert` modifiers that used those vars

Re-read lines 63–103. There are two `.sheet` modifiers (for `showingRecoveryKeySheet` and `showingRestoreSheet`) and one `.alert` (for `showingRevealedRecoveryKey`). Remove all three from the `.task` block's trailing chain.

- [ ] Re-read `ChatSettingsView.swift` lines 56–105
- [ ] Edit: delete the `.sheet(isPresented: $showingRecoveryKeySheet) { … }` block
- [ ] Edit: delete the `.sheet(isPresented: $showingRestoreSheet) { … }` block
- [ ] Edit: delete the `.alert("Recovery Key", isPresented: $showingRevealedRecoveryKey) { … }` block
- [ ] Re-read lines 42–105 to confirm all three removed cleanly

### Step 5.3 — Replace `backupSection` with a single nav row

Re-read `ChatSettingsView.swift` lines 245–360 (the `backupSection` computed property). Replace the entire `private var backupSection` with:

```swift
private var backupSection: some View {
    VStack(alignment: .leading, spacing: 12) {
        sectionTitle("Backup")

        NavigationLink { BackupView() } label: {
            chevronRow(
                icon: "icloud.and.arrow.up.fill",
                tint: SanchrColors.primary,
                background: Color(hex: 0xEEF2FF),
                title: "Backup & Recovery",
                subtitle: backupSubtitle
            )
        }
        .buttonStyle(.plain)
    }
}

private var backupSubtitle: String {
    let coordinator = container.backupCoordinator
    guard coordinator.isEnabled else { return "Off" }
    guard let lastBackupAt = coordinator.configuration?.lastBackupAt else {
        return "Enabled · No backups yet"
    }
    let interval = Date().timeIntervalSince(lastBackupAt)
    if interval < 3600 {
        let mins = max(1, Int(interval / 60))
        return "Last backed up \(mins)m ago"
    } else if interval < 86400 {
        let hours = Int(interval / 3600)
        return "Last backed up \(hours)h ago"
    } else {
        let days = Int(interval / 86400)
        return "Last backed up \(days)d ago"
    }
}
```

- [ ] Re-read `ChatSettingsView.swift` lines 245–360
- [ ] Edit: replace the entire `private var backupSection` body (lines 245–360) with the compact version above
- [ ] Re-read the replacement to confirm it rendered correctly

### Step 5.4 — Remove `BackupRecoveryKeySheet` and `BackupRestoreSheet` private structs

Re-read `ChatSettingsView.swift` from line 520 to the end. Delete the two private struct definitions (currently `BackupRestoreSheet` ~lines 522–558 and `BackupRecoveryKeySheet` ~lines 560–594).

- [ ] Re-read `ChatSettingsView.swift` lines 518–594
- [ ] Edit: delete `private struct BackupRestoreSheet { … }`
- [ ] Edit: delete `private struct BackupRecoveryKeySheet { … }`
- [ ] Re-read the file tail to confirm both are gone and the file ends with the closing `}`

### Step 5.5 — Also remove the `container.backupCoordinator.reload()` call from `.task`

Re-read the `.task` block (lines 56–62). The `container.backupCoordinator.reload()` call can stay (it's harmless), but **check**: if it was only needed to populate backup state for the inline section, it no longer matters since `BackupView` calls `reload()` itself. Leave the `.task` call as-is — it costs nothing and keeps the chat settings coordinator warm.

- [ ] Confirm `.task` still compiles correctly after the earlier edits (no dangling references to removed vars)

### Step 5.6 — Build + test

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild build -scheme Sanchr -destination "platform=iOS Simulator,name=iPhone 16" 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

```bash
xcodebuild test -scheme Sanchr -destination "platform=iOS Simulator,name=iPhone 16" 2>&1 | grep -E "Test Suite|passed|failed" | tail -10
```

Expected: all tests pass.

- [ ] Fix any errors before continuing

### Step 5.7 — Commit

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
git add ../Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift
git commit -m "feat(backup): replace ChatSettingsView inline backup section with BackupView nav row"
```

---

## Self-Review Checklist

### Spec coverage

| Spec requirement | Covered by |
|-----------------|------------|
| Two entry points (main Settings, Chat Settings) | Task 4 (SettingsView), Task 5 (ChatSettingsView) |
| `backupSubtitle` computed in both entry points | Task 4 + Task 5 |
| Disabled state: hero card, What's Backed Up, Restore row | Task 3 `disabledContent` |
| Enabled state: status card, toggle with disable confirmation | Task 3 `enabledContent` / `statusCard` |
| Storage chip (count + bytes) | Task 3 `statusCard` (historyState == .loaded) |
| Back Up Now with progress spinner | Task 3 `statusCard` |
| Recovery Key: View (biometric gate) + Rotate | Task 3 enabled section |
| `displayOnly` mode for BackupRecoveryKeySheet | Task 3 `BackupRecoveryKeySheet` |
| Backup History list with date/size/count, inline Restore | Task 3 `backupHistoryRows` |
| `BackupRestoreSheet` gains `backupId` param | Task 3 `BackupRestoreSheet` |
| Restore row always visible | Task 3 both states |
| Delete All Backups with confirmation | Task 3 danger zone |
| `listBackups()` on service + coordinator | Tasks 1 + 2 |
| `restoreBackup(backupId:)` on service + coordinator | Tasks 1 + 2 |
| Error handling paths | Task 3 (errorMessage captions), coordinator methods |
| Tests: listBackups sorted + messageCount | Task 2 |
| Tests: restoreBackup calls service with correct ID | Task 2 |
| ChatSettingsView sheets + @State removed | Task 5 |

### Placeholder scan

No TBDs, TODOs, or "implement later" entries exist in this plan.

### Type consistency

- `BackupListEntry.id: String` used as `backupId: String` throughout — consistent
- `BackupRecoveryKeySheet(displayOnly: Bool)` parameter matches usage in `BackupView` — consistent
- `BackupRestoreSheet(backupId: String?)` parameter matches usage in `BackupView` — consistent
- `coordinator.listBackups() async throws -> [BackupListEntry]` in coordinator matches service protocol — consistent
- `coordinator.restoreBackup(backupId: String, with recoveryKeyOverride: String?) async` — matches call sites in `BackupView` — consistent

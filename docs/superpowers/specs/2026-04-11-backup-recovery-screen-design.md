# Backup & Recovery Screen Design

## Goal

Replace the inline backup card buried in Chat Settings with a dedicated, full-featured Backup & Recovery screen accessible from both the main Settings list and Chat Settings.

## Architecture

**New files:**
- `ios/Sanchr-IOS/Features/Settings/Presentation/BackupView.swift` — dedicated screen (both disabled/enabled states, recovery key sheets, restore sheet)

**Modified files:**
- `ios/Sanchr-IOS/Features/Settings/Presentation/ChatSettingsView.swift` — entire backup section replaced with a single navigation row
- Main settings list view — adds top-level "Backup & Recovery" navigation row
- `ios/Sanchr-IOS/Shared/Services/BackupCoordinator.swift` — two new public methods

**No backend changes required.** `ListBackupsRequest` and `GetBackupDownloadRequest` (which accepts a `backup_id` field) are already defined in the proto.

---

## Screen: BackupView

### Navigation Entry Points

Two entry points lead to the same `BackupView`:

1. **Main Settings list** — a top-level "Backup & Recovery" row with a live subtitle: "Last backed up 2h ago" when enabled, "Off" when disabled.
2. **Chat Settings** — the existing multi-row backup card is removed and replaced with a single `NavigationLink` row using the same subtitle pattern.

### Disabled State

Shown when `backupCoordinator.isEnabled == false`.

**Sections (top to bottom):**

**Hero card**
- Shield icon in a purple-tinted tile
- Title: "Protect your chat history"
- Body: "Encrypted backups let you restore messages on a new device. Only you can read them — not even Sanchr."
- Primary CTA button: "Enable Backup" — calls `backupCoordinator.prepareEnableBackups()` then presents `BackupRecoveryKeySheet`

**What gets backed up** (section label: "WHAT GETS BACKED UP")
- Row 1 — 💬 Messages & conversations / "All chats, group info, contacts"
- Row 2 — 🔐 Vault items / "Encrypted vault media & keys"
- Row 3 — 🖼️ Photos & videos / "Re-downloaded from Sanchr on restore"

This section is informational only (no interaction). It sets honest expectations — media bytes are not in the archive; they re-download from the server on first view after restore.

**Restore** (section label: "RESTORE")
- Single row: 📥 "Restore from Backup" / "Bring history to this device" — presents `BackupRestoreSheet`
- Always visible even when backup is disabled. A user setting up a new device has not yet re-enabled backup.

### Enabled State

Shown when `backupCoordinator.isEnabled == true`.

**Status card** (no section label — top-level anchor)
- Icon tile (shield, purple background) + "Backup Active" title + green "✓ Up to date · X hours ago" subtitle
- Toggle bound to `backupCoordinator.isEnabled`; disabling calls `backupCoordinator.disableBackups()` after a confirmation alert ("Disable backup? Your existing backups will remain on the server until you delete them.")
- Storage summary chip: "N backups · X.X MB stored" — derived from `listBackups()` result (sum of `byteSize`, count of entries)
- "Back Up Now" button — calls `backupCoordinator.backupNow(force: true)`; shows `ProgressView` in-place while `isProcessing == true`

**Recovery Key** (section label: "RECOVERY KEY")
- Row 1 — 🔑 "View Recovery Key" / "Face ID required" — calls `backupCoordinator.revealRecoveryKey()` (biometric gate is inside `BackupCoordinator`); on success presents `BackupRecoveryKeySheet` in read-only display mode
- Row 2 — 🔄 "Rotate Recovery Key" / "Generate a new key" — calls `backupCoordinator.rotateRecoveryKey()` then presents `BackupRecoveryKeySheet` for confirmation
- Footer note: "Save your recovery key somewhere safe. Without it you cannot restore your backup on a new device."

**Backup History** (section label: "BACKUP HISTORY")
- Populated by `backupCoordinator.listBackups()` called in `.task` on view appear
- Each row shows: date/time (formatted as "Today, 4:12 PM" / "Yesterday, 10:07 AM" / "Apr 9, 8:44 PM"), byte size, message count
- Each row has an inline "Restore" tappable label (blue, `.sanchrPrimary`) — tapping presents `BackupRestoreSheet` pre-seeded with that `backupId`
- While loading, rows show a `ProgressView` placeholder
- On load error, shows a single row: "Could not load history" in tertiary text

**Restore** (section label: "RESTORE")
- Row: 📥 "Restore from Backup" / "Recover on a new device" — presents `BackupRestoreSheet` without a pre-seeded backup ID (uses latest)

**Danger zone** (no section label)
- Single row: "Delete All Backups" in `.sanchrError` red — calls `backupCoordinator.deleteRemoteBackups()` after a confirmation alert ("Delete all backups? This cannot be undone.")

---

## BackupCoordinator Changes

### New method: `listBackups()`

```swift
struct BackupListEntry: Identifiable, Sendable {
    let id: String        // backup_id
    let committedAt: Date
    let byteSize: Int64
    let messageCount: Int?  // parsed from opaqueMetadata JSON counts.messages; nil if unparseable
}

func listBackups() async throws -> [BackupListEntry]
```

Implementation: calls `backupService.listBackups()` (existing `ListBackupsRequest` gRPC), maps each `BackupMetadata` proto to `BackupListEntry`. Parses `opaqueMetadata` JSON to extract `counts.messages`. Returns sorted descending by `committedAt`.

### New method: `restoreBackup(backupId:with:)`

```swift
func restoreBackup(backupId: String, with recoveryKeyOverride: String?) async throws
```

Identical to `restoreLatestBackup(with:)` except it calls `backupService.getBackupDownload(backupId: backupId)` directly instead of listing all backups and picking the latest. The existing `restoreLatestBackup` remains unchanged (used when restoring from the generic "Restore" row with no specific version selected).

---

## Sheet Components

Both sheets move from their current inline location inside `ChatSettingsView.swift` into `BackupView.swift`. Their logic and appearance do not change.

**BackupRecoveryKeySheet** — used for:
- First-time setup (shows key, requires "I saved this key" confirmation)
- Key rotation (same flow)
- Key reveal after biometric auth (display-only mode — no confirmation button, just "Close")

Add a `displayOnly: Bool` parameter (default `false`) to support the reveal case. When `displayOnly: true`, the sheet shows only the key text and a "Close" button — the "I saved this key" confirmation button is hidden.

**BackupRestoreSheet** — gains an optional `backupId: String?` parameter. When non-nil, the restore action calls `restoreBackup(backupId:with:)` instead of `restoreLatestBackup(with:)`.

---

## ChatSettingsView Changes

The entire `backupSection` computed property is replaced with a single `NavigationLink` row using the existing `chevronRow` helper:

```swift
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
```

Where `backupSubtitle` is a computed property:
- Enabled + last backup date available → "Last backed up X ago"
- Enabled + no backup yet → "Enabled · No backups yet"
- Disabled → "Off"

The two sheet structs (`BackupRecoveryKeySheet`, `BackupRestoreSheet`) and all coordinator-related `@State` variables move to `BackupView.swift`.

---

## Error Handling

- `backupNow` failure → sets `backupCoordinator.errorMessage`; `BackupView` shows it as a red caption below the status card
- `listBackups` failure → history section shows "Could not load history" row
- `restoreBackup` failure → `BackupRestoreSheet` shows inline error text above the restore button
- `revealRecoveryKey` failure → no sheet presented; `BackupView` shows `errorMessage` caption
- All destructive confirmations (disable backup, delete all backups) use SwiftUI `.alert` with `.destructive` button role

---

## Testing

- `BackupCoordinator` is already testable via its protocol-based dependencies; new methods follow the same pattern
- `listBackups` test: mock `BackupArchiveServiceProtocol` returning N `BackupMetadata` entries; assert sorted order, correct byte sum, message count parsing
- `restoreBackup(backupId:)` test: verify it calls `getBackupDownload` with the correct ID rather than `listBackups`
- UI: `BackupView` should preview correctly in both disabled and enabled states using a mock coordinator

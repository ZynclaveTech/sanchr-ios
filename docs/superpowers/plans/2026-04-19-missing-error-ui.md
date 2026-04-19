# Missing Error UI in Settings Flows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add proper error UI to Settings screens so users see specific error messages instead of silent failures.

**Architecture:** Add error state properties to view models/views, capture error details in catch blocks, and display errors via alerts or status text. Each flow will show the actual error reason to the user instead of silently failing or showing generic messages.

**Tech Stack:** SwiftUI, LocalAuthentication framework, SanchrLogger, existing SettingsViewModel pattern

---

## Task 1: Fix SecurityView Biometric Lock Error Handling

**Files:**
- Modify: `Features/Settings/Presentation/SecurityView.swift:395-396`

**Context:** When users toggle biometric lock, if LAContext.evaluatePolicy throws an error, the code currently just sets `biometricLock = false` without showing an error message. Users think they cancelled the prompt rather than knowing an error occurred.

- [ ] **Step 1: Read the current implementation**

```bash
grep -A5 -B5 "catch {" /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS/Features/Settings/Presentation/SecurityView.swift | grep -A5 "context.evaluatePolicy"
```

Expected output shows the error handler at line 395 with no errorMessage assignment.

- [ ] **Step 2: Update the catch block to set errorMessage**

Edit `/Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS/Features/Settings/Presentation/SecurityView.swift`:

```swift
            } catch {
                viewModel.biometricLock = false
                viewModel.errorMessage = error.localizedDescription
            }
```

Replace the current lines 394-396:

```swift
            } catch {
                viewModel.biometricLock = false
            }
```

With the code above that includes `viewModel.errorMessage = error.localizedDescription`.

- [ ] **Step 3: Verify the change was applied correctly**

```bash
sed -n '394,396p' /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS/Features/Settings/Presentation/SecurityView.swift
```

Expected: Three lines showing the updated catch block with errorMessage assignment.

- [ ] **Step 4: Commit the change**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && git add Features/Settings/Presentation/SecurityView.swift && git commit -m "fix: Display biometric lock error message to user instead of silently failing"
```

---

## Task 2: Add Error UI to BlockedContactsView

**Files:**
- Modify: `Features/Settings/Presentation/BlockedContactsView.swift`

**Context:** BlockedContactsView has two error scenarios:
1. Loading blocked contacts list fails (line 78-80)
2. Unblocking a contact fails (line 91-93)

Both are logged but not displayed to users. Need to add error state and show errors in an alert.

- [ ] **Step 1: Add error state property**

Edit `/Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift` at line 8 (after `@State private var isLoading = false`):

Add this line:

```swift
    @State private var errorMessage: String?
```

So the state section becomes:

```swift
    @State private var blockedIDs: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
```

- [ ] **Step 2: Update loadBlocked error handler to set errorMessage**

Replace lines 78-80:

```swift
        } catch {
            SanchrLogger.sync.error("Failed to load blocked list: \(error.localizedDescription)")
        }
```

With:

```swift
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.sync.error("Failed to load blocked list: \(error.localizedDescription)")
        }
```

- [ ] **Step 3: Update unblock error handler to set errorMessage**

Replace lines 91-93:

```swift
        } catch {
            SanchrLogger.sync.error("Failed to unblock: \(error.localizedDescription)")
        }
```

With:

```swift
        } catch {
            errorMessage = error.localizedDescription
            SanchrLogger.sync.error("Failed to unblock: \(error.localizedDescription)")
        }
```

- [ ] **Step 4: Add error alert to the view**

Add this modifier chain to the ScrollView in the body (before `.background()`). Insert after line 56:

```swift
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
```

So the complete structure is:

```swift
    var body: some View {
        ScrollView(showsIndicators: false) {
            // ... existing content ...
        }
        .background(SanchrExportColors.surfaceSoft.ignoresSafeArea())
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
```

- [ ] **Step 5: Verify the changes**

```bash
grep -n "@State.*errorMessage\|errorMessage = \|.alert(\"Error\"" /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS/Features/Settings/Presentation/BlockedContactsView.swift
```

Expected: At least 5 matches showing errorMessage state, assignments in both catch blocks, and alert modifier.

- [ ] **Step 6: Commit the changes**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && git add Features/Settings/Presentation/BlockedContactsView.swift && git commit -m "fix: Show error alerts in BlockedContactsView for load and unblock failures"
```

---

## Task 3: Add Error Details to BackupView History Loading

**Files:**
- Modify: `Features/Settings/Presentation/BackupView.swift:10-23,447`

**Context:** BackupView's `loadHistory()` function fails silently and shows generic "Could not load history" message. Need to capture actual error and display it.

- [ ] **Step 1: Add error message state property**

Read lines 1-25 to find where to add the state:

```bash
sed -n '1,25p' /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS/Features/Settings/Presentation/BackupView.swift
```

Add `@State private var lastLoadError: String?` after line 22 (after `@State private var restoreRecoveryKey = ""`).

The section should be:

```swift
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
```

- [ ] **Step 2: Update loadHistory to capture error details**

Replace lines 441-449:

```swift
    private func loadHistory() async {
        historyState = .loading
        do {
            backupHistory = try await container.backupCoordinator.listBackups()
            historyState = .loaded
        } catch {
            historyState = .failed
        }
    }
```

With:

```swift
    private func loadHistory() async {
        historyState = .loading
        do {
            backupHistory = try await container.backupCoordinator.listBackups()
            historyState = .loaded
            lastLoadError = nil
        } catch {
            lastLoadError = error.localizedDescription
            historyState = .failed
        }
    }
```

- [ ] **Step 3: Update the failed state UI to show error details**

Find the `.failed` case display (around line 323). Read lines 320-327:

```bash
sed -n '320,327p' /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS/Features/Settings/Presentation/BackupView.swift
```

Replace the generic message with error-specific text:

```swift
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
```

- [ ] **Step 4: Verify the changes**

```bash
grep -n "lastLoadError\|error.localizedDescription" /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS/Features/Settings/Presentation/BackupView.swift
```

Expected: Multiple matches showing lastLoadError state declaration, assignment in loadHistory, and use in UI.

- [ ] **Step 5: Commit the changes**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && git add Features/Settings/Presentation/BackupView.swift && git commit -m "fix: Display actual error message when backup history fails to load"
```

---

## Verification

After all tasks are complete, verify the changes work correctly:

- [ ] **Step 1: Type check the entire project**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS && timeout 120 xcodebuild build -scheme Sanchr -configuration Debug 2>&1 | grep -E "error:" | grep -v "Provisioning profile"
```

Expected: No Swift compilation errors (provisioning profile issues are environment-specific).

- [ ] **Step 2: Review the complete commit history**

```bash
git log --oneline -3
```

Expected: Three new commits showing the three fixes.

---

## Summary

These changes add proper error handling UI to three Settings flows:
1. **SecurityView** - Shows biometric authentication errors instead of silent failure
2. **BlockedContactsView** - Shows load and unblock operation errors in alerts
3. **BackupView** - Shows specific error messages when history loading fails

Users will now see what went wrong and can take appropriate action (retry, check connectivity, etc.) instead of silently failing operations.

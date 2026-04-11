# Encrypted Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Encrypt `displayName`, `bio`, and `avatarURL` with a per-user 32-byte Profile Key before sending them to the server, and decrypt them on receipt so the server never stores plaintext identity fields.

**Architecture:** A new `ProfileCryptor` derives per-field subkeys from the master Profile Key via HKDF-SHA256, then encrypts each UTF-8 field with AES-256-GCM. A `ProfileKeyStore` persists the own key and received contact keys in the iOS Keychain. The `UpdateProfile` use case gains the two new deps and encrypts before calling `ProfileDataSource`. `ContactRepositoryImpl.fetchContacts` decrypts opportunistically when a `profileKey` is present in the wire response, falling back to the plaintext fields so old server builds remain compatible.

**Tech Stack:** Swift, CryptoKit (HKDF + AES-256-GCM), Security framework (SecRandomCopyBytes), KeychainService, SwiftProtobuf, GRPC-Swift, GRDB, XCTest

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `SanchrShared/Crypto/ProfileCrypto.swift` | **Create** | `ProfileField` enum + `ProfileCryptoProtocol` + `ProfileCryptor` impl |
| `Tests/UnitTests/ProfileCryptoTests.swift` | **Create** | Round-trip, domain-separation, nonce-randomness, tamper tests |
| `SanchrShared/Crypto/ProfileKeyStore.swift` | **Create** | `ProfileKeyStoreProtocol` + `ProfileKeyStore` (Keychain-backed) |
| `Tests/UnitTests/ProfileKeyStoreTests.swift` | **Create** | Stability, length, round-trip, absent-user tests |
| `SanchrShared/Models/User.swift` | **Modify** | Add `profileKey: Data? = nil` field + update init |
| `SanchrShared/Persistence/DatabaseRecords.swift` | **Modify** | Add `profileKey: Data?` to `UserRecord`; update init/toDomain |
| `SanchrShared/Persistence/DatabaseSchema.swift` | **Modify** | Add migration `v8_user_profile_key` |
| `Proto/settings.proto` | **Modify** | Add encrypted bytes fields to `UpdateProfileRequest` / `ProfileResponse` |
| `Proto/contacts.proto` | **Modify** | Add encrypted bytes fields to `Contact` / `MatchedContact` |
| `SanchrShared/Generated/settings.pb.swift` | **Modify** | Add Swift properties + decode/traverse/== for new fields |
| `SanchrShared/Generated/contacts.pb.swift` | **Modify** | Add Swift properties + decode/traverse/== for new fields |
| `Features/Profile/Data/ProfileDataSource.swift` | **Modify** | Extract `ProfileDataSourceProtocol`; add encrypted params to `updateProfile` |
| `Features/Profile/Domain/ProfileUseCases.swift` | **Modify** | `UpdateProfile` gains `profileKeyStore` + `profileCrypto`; encrypts before send |
| `Features/Profile/Presentation/ProfileViewModel.swift` | **Modify** | `saveProfile` signature gains `profileKeyStore` + `profileCrypto` params |
| `Features/Profile/Presentation/ProfileView.swift` | **Modify** | Provide `ProfileKeyStore` + `ProfileCryptor` from container at call site |
| `Tests/UnitTests/ProfileUseCasesEncryptionTests.swift` | **Create** | Verify non-empty profileKey + encrypted field sent to data source |
| `Shared/Repositories/ContactRepository.swift` | **Modify** | `ContactRepositoryImpl` gains crypto deps; decrypt on fetch |
| `App/DependencyContainer.swift` | **Modify** | Add lazy `profileKeyStore` + `profileCrypto`; update `contactRepository` init |
| `Tests/UnitTests/ContactRepositoryDecryptTests.swift` | **Create** | FakeChannel-based test: Contact with profileKey → decrypted User.displayName |

---

### Task 1: ProfileCrypto — HKDF field key derivation + AES-256-GCM cipher

**Files:**
- Create: `SanchrShared/Crypto/ProfileCrypto.swift`
- Test: `Tests/UnitTests/ProfileCryptoTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UnitTests/ProfileCryptoTests.swift
import XCTest
import CryptoKit
import SanchrShared
@testable import Sanchr

final class ProfileCryptoTests: XCTestCase {
    let crypto = ProfileCryptor()
    let key = Data(repeating: 0xAB, count: 32)

    func test_encryptField_producesNonEmptyData() throws {
        let ct = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        XCTAssertFalse(ct.isEmpty)
    }

    func test_encryptField_decryptField_roundtrips() throws {
        let plaintext = "Hello, World! 🌍"
        let ct = try crypto.encryptField(plaintext, profileKey: key, field: .displayName)
        let recovered = try crypto.decryptField(ct, profileKey: key, field: .displayName)
        XCTAssertEqual(recovered, plaintext)
    }

    func test_encryptField_differentFields_produceDifferentCiphertext() throws {
        // Same plaintext + same master key but different field label → different subkey → different ct
        let ct1 = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        let ct2 = try crypto.encryptField("Alice", profileKey: key, field: .bio)
        XCTAssertNotEqual(ct1, ct2, "each ProfileField must derive an independent subkey")
    }

    func test_encryptField_sameInputTwice_differentNonce() throws {
        let ct1 = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        let ct2 = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        XCTAssertNotEqual(ct1, ct2, "AES-GCM must use a fresh random nonce on every call")
    }

    func test_decryptField_tamperedCiphertext_throws() throws {
        var ct = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        ct[ct.count - 1] ^= 0xFF   // corrupt the GCM authentication tag
        XCTAssertThrowsError(
            try crypto.decryptField(ct, profileKey: key, field: .displayName),
            "tampered ciphertext must not decrypt successfully"
        )
    }

    func test_decryptField_wrongKey_throws() throws {
        let ct = try crypto.encryptField("Alice", profileKey: key, field: .displayName)
        let wrongKey = Data(repeating: 0x00, count: 32)
        XCTAssertThrowsError(
            try crypto.decryptField(ct, profileKey: wrongKey, field: .displayName),
            "wrong key must not decrypt successfully"
        )
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail (type not found)**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/ProfileCryptoTests \
  2>&1 | grep -E "FAILED|PASSED|error:|ProfileCrypto"
```

Expected: Build error — `ProfileCryptor` is not defined.

- [ ] **Step 3: Create `ProfileCrypto.swift`**

```swift
// SanchrShared/Crypto/ProfileCrypto.swift
import CryptoKit
import Foundation

/// Identifies which profile field is being encrypted.
/// The raw value is the HKDF info string — different fields derive different subkeys,
/// preventing cross-field ciphertext reuse.
public enum ProfileField: String, Sendable {
    case displayName = "sanchr-profile-display-name-v1"
    case bio         = "sanchr-profile-bio-v1"
    case avatarURL   = "sanchr-profile-avatar-url-v1"
}

/// Encrypts and decrypts individual profile fields using a per-field AES-256-GCM key
/// derived from a 32-byte master Profile Key via HKDF-SHA256.
public protocol ProfileCryptoProtocol: Sendable {
    /// Encrypts `plaintext` using a subkey derived from `profileKey` for `field`.
    /// Returns AES-GCM combined output (12-byte nonce ‖ ciphertext ‖ 16-byte tag).
    func encryptField(_ plaintext: String, profileKey: Data, field: ProfileField) throws -> Data

    /// Decrypts a ciphertext produced by `encryptField`.
    func decryptField(_ ciphertext: Data, profileKey: Data, field: ProfileField) throws -> String
}

/// Concrete AES-256-GCM implementation of `ProfileCryptoProtocol`.
public final class ProfileCryptor: ProfileCryptoProtocol, @unchecked Sendable {
    public init() {}

    // MARK: - ProfileCryptoProtocol

    public func encryptField(
        _ plaintext: String,
        profileKey: Data,
        field: ProfileField
    ) throws -> Data {
        guard let plaintextData = plaintext.data(using: .utf8) else {
            throw AppError.encryptionFailed(reason: "profile field is not valid UTF-8")
        }
        let fieldKey = deriveFieldKey(profileKey: profileKey, field: field)
        let symmetricKey = SymmetricKey(data: fieldKey)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintextData, using: symmetricKey, nonce: nonce)
        guard let combined = box.combined else {
            throw AppError.encryptionFailed(reason: "AES-GCM produced no combined output")
        }
        return combined
    }

    public func decryptField(
        _ ciphertext: Data,
        profileKey: Data,
        field: ProfileField
    ) throws -> String {
        let fieldKey = deriveFieldKey(profileKey: profileKey, field: field)
        let symmetricKey = SymmetricKey(data: fieldKey)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintextData: Data
        do {
            plaintextData = try AES.GCM.open(box, using: symmetricKey)
        } catch {
            throw AppError.decryptionFailed(reason: "profile field AES-GCM open failed: \(error)")
        }
        guard let plaintext = String(data: plaintextData, encoding: .utf8) else {
            throw AppError.decryptionFailed(reason: "decrypted profile field is not valid UTF-8")
        }
        return plaintext
    }

    // MARK: - Key Derivation

    private func deriveFieldKey(profileKey: Data, field: ProfileField) -> Data {
        let ikm = SymmetricKey(data: profileKey)
        let info = Data(field.rawValue.utf8)
        // No salt: HKDF-SHA256 with empty salt is standard for key derivation from a
        // uniformly random IKM. The info string provides domain separation per field.
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            info: info,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/ProfileCryptoTests \
  2>&1 | grep -E "FAILED|PASSED|error:|ProfileCrypto"
```

Expected: 6 tests **PASS**.

- [ ] **Step 5: Confirm no regressions**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | tail -5
```

Expected: Same pass count as before, 0 new failures.

- [ ] **Step 6: Commit**

```bash
git add SanchrShared/Crypto/ProfileCrypto.swift \
        Tests/UnitTests/ProfileCryptoTests.swift
git commit -m "feat: add ProfileCryptor — HKDF field-key derivation + AES-256-GCM profile field cipher"
```

---

### Task 2: ProfileKeyStore — Keychain-backed profile key storage

**Files:**
- Create: `SanchrShared/Crypto/ProfileKeyStore.swift`
- Test: `Tests/UnitTests/ProfileKeyStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UnitTests/ProfileKeyStoreTests.swift
import XCTest
import SanchrShared
@testable import Sanchr

final class ProfileKeyStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() -> ProfileKeyStore {
        ProfileKeyStore(keychain: MockKeychainService())
    }

    // MARK: - Own key tests

    func test_ownProfileKey_generates32Bytes() throws {
        let key = try makeStore().ownProfileKey()
        XCTAssertEqual(key.count, 32, "profile key must be exactly 32 bytes")
    }

    func test_ownProfileKey_isStable_acrossMultipleCalls() throws {
        let store = makeStore()
        let first  = try store.ownProfileKey()
        let second = try store.ownProfileKey()
        XCTAssertEqual(first, second, "ownProfileKey must return the same key on successive calls")
    }

    func test_ownProfileKey_isUnique_perStoreInstance() throws {
        // Each new store backed by a fresh empty MockKeychainService generates a new key.
        // Probability of accidental collision is 2^-256 — effectively impossible.
        let key1 = try makeStore().ownProfileKey()
        let key2 = try makeStore().ownProfileKey()
        XCTAssertNotEqual(key1, key2, "distinct empty keystores must produce distinct random keys")
    }

    // MARK: - Contact key tests

    func test_saveAndRead_contactProfileKey_roundtrips() throws {
        let store = makeStore()
        let key = Data(repeating: 0xCC, count: 32)
        try store.saveContactProfileKey(key, forUserId: "user-42")
        let retrieved = try store.contactProfileKey(forUserId: "user-42")
        XCTAssertEqual(retrieved, key)
    }

    func test_contactProfileKey_absentUser_returnsNil() throws {
        let retrieved = try makeStore().contactProfileKey(forUserId: "nobody")
        XCTAssertNil(retrieved)
    }

    func test_deleteContactProfileKey_removesEntry() throws {
        let store = makeStore()
        let key = Data(repeating: 0xDD, count: 32)
        try store.saveContactProfileKey(key, forUserId: "user-99")
        try store.deleteContactProfileKey(forUserId: "user-99")
        let result = try store.contactProfileKey(forUserId: "user-99")
        XCTAssertNil(result, "deleted contact key must not be retrievable")
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/ProfileKeyStoreTests \
  2>&1 | grep -E "FAILED|PASSED|error:|ProfileKeyStore"
```

Expected: Build error — `ProfileKeyStore` is not defined.

- [ ] **Step 3: Create `ProfileKeyStore.swift`**

```swift
// SanchrShared/Crypto/ProfileKeyStore.swift
import Foundation
import Security

/// Persists the local user's own Profile Key and received contacts' Profile Keys in the iOS Keychain.
///
/// Own key lifecycle: generated once on first call to `ownProfileKey()`, then read from Keychain
/// on all subsequent calls. Never changes unless the user explicitly resets (out of scope here).
///
/// Contact key lifecycle: populated from the `profile_key` bytes field in `GetContactsResponse`
/// whenever a contact is fetched. Used by `ContactRepositoryImpl` to decrypt profile fields.
public protocol ProfileKeyStoreProtocol: AnyObject, Sendable {
    /// Returns the local user's 32-byte Profile Key, generating and persisting it on first call.
    func ownProfileKey() throws -> Data

    /// Persists (or overwrites) a contact's Profile Key in the Keychain.
    func saveContactProfileKey(_ key: Data, forUserId userId: String) throws

    /// Reads a contact's Profile Key, or returns `nil` if not yet received.
    func contactProfileKey(forUserId userId: String) throws -> Data?

    /// Removes a contact's stored Profile Key (e.g. when a contact is deleted).
    func deleteContactProfileKey(forUserId userId: String) throws
}

public final class ProfileKeyStore: ProfileKeyStoreProtocol, @unchecked Sendable {

    // MARK: - Keychain key strings

    private enum Keys {
        static let ownKey = "profile.key.own"
        static func contactKey(for userId: String) -> String {
            "profile.key.contact.\(userId)"
        }
    }

    private let keychain: KeychainServiceProtocol

    public init(keychain: KeychainServiceProtocol) {
        self.keychain = keychain
    }

    // MARK: - ProfileKeyStoreProtocol

    public func ownProfileKey() throws -> Data {
        if let existing = try keychain.read(forKey: Keys.ownKey) {
            return existing
        }
        // Generate a fresh random 32-byte key and persist it.
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard status == errSecSuccess else {
            SanchrLogger.crypto.error("ProfileKeyStore: SecRandomCopyBytes failed: \(status)")
            throw AppError.keyGenerationFailed
        }
        let key = Data(bytes)
        try keychain.save(key, forKey: Keys.ownKey)
        return key
    }

    public func saveContactProfileKey(_ key: Data, forUserId userId: String) throws {
        try keychain.save(key, forKey: Keys.contactKey(for: userId))
    }

    public func contactProfileKey(forUserId userId: String) throws -> Data? {
        try keychain.read(forKey: Keys.contactKey(for: userId))
    }

    public func deleteContactProfileKey(forUserId userId: String) throws {
        try keychain.delete(forKey: Keys.contactKey(for: userId))
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/ProfileKeyStoreTests \
  2>&1 | grep -E "FAILED|PASSED|error:|ProfileKeyStore"
```

Expected: 6 tests **PASS**.

- [ ] **Step 5: Confirm no regressions**

```bash
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add SanchrShared/Crypto/ProfileKeyStore.swift \
        Tests/UnitTests/ProfileKeyStoreTests.swift
git commit -m "feat: add ProfileKeyStore — Keychain-backed own + contact profile key persistence"
```

---

### Task 3: Extend User model and GRDB schema

**Files:**
- Modify: `SanchrShared/Models/User.swift`
- Modify: `SanchrShared/Persistence/DatabaseRecords.swift`
- Modify: `SanchrShared/Persistence/DatabaseSchema.swift`

- [ ] **Step 1: Add `profileKey` to `User.swift`**

In `SanchrShared/Models/User.swift`, add the property after `identityKeyFingerprint`:

```swift
// existing line:
public var identityKeyFingerprint: String?
// ADD after it:
/// The sender's 32-byte Profile Key, present when the server has provided it.
/// `nil` means the profile has not yet been received with encrypted fields.
public var profileKey: Data? = nil
```

Add `profileKey` to the init after `identityKeyFingerprint`:

```swift
// existing:
public init(
    id: String,
    phoneNumber: String,
    displayName: String,
    avatarURL: URL? = nil,
    bio: String? = nil,
    isVerified: Bool,
    lastSeen: Date? = nil,
    identityKeyFingerprint: String? = nil,
    status: Status,
    isLocalUser: Bool = false
) {
// REPLACE with:
public init(
    id: String,
    phoneNumber: String,
    displayName: String,
    avatarURL: URL? = nil,
    bio: String? = nil,
    isVerified: Bool,
    lastSeen: Date? = nil,
    identityKeyFingerprint: String? = nil,
    status: Status,
    isLocalUser: Bool = false,
    profileKey: Data? = nil
) {
```

Add assignment inside init body before the closing `}`:
```swift
        self.profileKey = profileKey
```

- [ ] **Step 2: Add `profileKey` to `UserRecord` in `DatabaseRecords.swift`**

Add the property after `isLocalUser`:
```swift
// existing:
    public var isLocalUser: Bool
// ADD after:
    public var profileKey: Data?
```

Update `init(from user: User)` — add after `self.isLocalUser = user.isLocalUser`:
```swift
        self.profileKey = user.profileKey
```

Update the explicit memberwise `init(...)` — add parameter after `isLocalUser: Bool`:
```swift
        isLocalUser: Bool,
        profileKey: Data? = nil
```
And inside that init body, add:
```swift
        self.profileKey = profileKey
```

Update `toDomain()` — add `profileKey: profileKey` to the `User(...)` call:
```swift
    public func toDomain() -> User {
        User(
            id: id,
            phoneNumber: phoneNumber,
            displayName: displayName,
            avatarURL: avatarURL.flatMap { URL(string: $0) },
            bio: bio,
            isVerified: isVerified,
            lastSeen: lastSeen,
            identityKeyFingerprint: identityKeyFingerprint,
            status: User.Status(rawValue: status) ?? .offline,
            isLocalUser: isLocalUser,
            profileKey: profileKey
        )
    }
```

- [ ] **Step 3: Add GRDB migration in `DatabaseSchema.swift`**

After the closing `}` of migration `v7_vault_items_forward_secure`, add:

```swift
        migrator.registerMigration("v8_user_profile_key") { db in
            try db.alter(table: "user") { t in
                // Nullable blob; nil until the server sends the field for this contact.
                t.add(column: "profileKey", .blob)
            }
        }
```

- [ ] **Step 4: Build to verify compilation**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`. Fix any missing-argument errors in call sites that use `User(...)` explicitly (add `profileKey: nil` at each).

- [ ] **Step 5: Run full test suite**

```bash
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | tail -5
```

Expected: Same pass count, 0 new failures. (Migration v8 runs on fresh test databases automatically.)

- [ ] **Step 6: Commit**

```bash
git add SanchrShared/Models/User.swift \
        SanchrShared/Persistence/DatabaseRecords.swift \
        SanchrShared/Persistence/DatabaseSchema.swift
git commit -m "feat: add profileKey to User model and GRDB migration v8"
```

---

### Task 4: Proto additions and Swift codegen

**Files:**
- Modify: `Proto/settings.proto`
- Modify: `Proto/contacts.proto`
- Modify: `SanchrShared/Generated/settings.pb.swift`
- Modify: `SanchrShared/Generated/contacts.pb.swift`

**Note:** After modifying the `.proto` files, run `./Scripts/generate-protos.sh` to regenerate. If `protoc` / `protoc-gen-swift` are not installed, apply the manual Swift patches in Steps 4–7 instead and skip Step 3.

- [ ] **Step 1: Update `Proto/settings.proto`**

Replace `UpdateProfileRequest` and `ProfileResponse` with:

```proto
message UpdateProfileRequest {
  string display_name = 1;
  string avatar_url   = 2;
  string status_text  = 3;
  // Encrypted profile fields (AES-256-GCM; server stores as opaque blobs).
  bytes profile_key             = 4;
  bytes encrypted_display_name  = 5;
  bytes encrypted_bio           = 6;
  bytes encrypted_avatar_url    = 7;
}

message ProfileResponse {
  string id           = 1;
  string display_name = 2;
  string avatar_url   = 3;
  string status_text  = 4;
  // Server echoes back the encrypted fields so the caller can verify persistence.
  bytes profile_key             = 5;
  bytes encrypted_display_name  = 6;
  bytes encrypted_bio           = 7;
  bytes encrypted_avatar_url    = 8;
}
```

- [ ] **Step 2: Update `Proto/contacts.proto`**

Append fields to `MatchedContact` and `Contact`:

```proto
message MatchedContact {
  string user_id      = 1;
  string display_name = 2;
  string avatar_url   = 3;
  string status_text  = 4;
  string phone_number = 5;
  // Encrypted profile fields
  bytes profile_key             = 6;
  bytes encrypted_display_name  = 7;
  bytes encrypted_bio           = 8;
  bytes encrypted_avatar_url    = 9;
}

message Contact {
  string user_id      = 1;
  string display_name = 2;
  string avatar_url   = 3;
  string status_text  = 4;
  bool   is_blocked   = 5;
  bool   is_favorite  = 6;
  string phone_number = 7;
  // Encrypted profile fields
  bytes profile_key             = 8;
  bytes encrypted_display_name  = 9;
  bytes encrypted_bio           = 10;
  bytes encrypted_avatar_url    = 11;
}
```

- [ ] **Step 3: Regenerate Swift files (preferred path)**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
./Scripts/generate-protos.sh
```

Expected: `Done. Generated files in SanchrShared/Generated`.

Review `git diff SanchrShared/Generated/` — accept changes, revert any cosmetic drift you don't want (the script note in the file mentions `internal`→`public` hand-edits may be reverted; that is fine).

Then **skip Steps 4–7** and go directly to Step 8.

---

**If generate-protos.sh is unavailable, apply these manual patches instead (Steps 4–7):**

- [ ] **Step 4: Manually patch `settings.pb.swift` — `UpdateProfileRequest` struct**

In the `Sanchr_Settings_UpdateProfileRequest` struct (around line 176), add four properties after `public var statusText: String = String()`:

```swift
  public var profileKey: Data = Data()
  public var encryptedDisplayName: Data = Data()
  public var encryptedBio: Data = Data()
  public var encryptedAvatarURL: Data = Data()
```

In `extension Sanchr_Settings_UpdateProfileRequest`, update `_protobuf_nameMap`:

```swift
  public static let _protobuf_nameMap = SwiftProtobuf._NameMap(bytecode: "\0\u{3}display_name\0\u{3}avatar_url\0\u{3}status_text\0\u{3}profile_key\0\u{3}encrypted_display_name\0\u{3}encrypted_bio\0\u{3}encrypted_avatar_url\0")
```

In `decodeMessage`, add after `case 3`:

```swift
      case 4: try { try decoder.decodeSingularBytesField(value: &self.profileKey) }()
      case 5: try { try decoder.decodeSingularBytesField(value: &self.encryptedDisplayName) }()
      case 6: try { try decoder.decodeSingularBytesField(value: &self.encryptedBio) }()
      case 7: try { try decoder.decodeSingularBytesField(value: &self.encryptedAvatarURL) }()
```

In `traverse`, add after the `statusText` block:

```swift
    if !self.profileKey.isEmpty {
      try visitor.visitSingularBytesField(value: self.profileKey, fieldNumber: 4)
    }
    if !self.encryptedDisplayName.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedDisplayName, fieldNumber: 5)
    }
    if !self.encryptedBio.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedBio, fieldNumber: 6)
    }
    if !self.encryptedAvatarURL.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedAvatarURL, fieldNumber: 7)
    }
```

In `==`, add before `if lhs.unknownFields != rhs.unknownFields`:

```swift
    if lhs.profileKey != rhs.profileKey {return false}
    if lhs.encryptedDisplayName != rhs.encryptedDisplayName {return false}
    if lhs.encryptedBio != rhs.encryptedBio {return false}
    if lhs.encryptedAvatarURL != rhs.encryptedAvatarURL {return false}
```

- [ ] **Step 5: Manually patch `settings.pb.swift` — `ProfileResponse` struct**

In `Sanchr_Settings_ProfileResponse` struct (around line 192), add after `public var statusText: String = String()`:

```swift
  public var profileKey: Data = Data()
  public var encryptedDisplayName: Data = Data()
  public var encryptedBio: Data = Data()
  public var encryptedAvatarURL: Data = Data()
```

In the extension, update `_protobuf_nameMap`:

```swift
  public static let _protobuf_nameMap = SwiftProtobuf._NameMap(bytecode: "\0\u{1}id\0\u{3}display_name\0\u{3}avatar_url\0\u{3}status_text\0\u{3}profile_key\0\u{3}encrypted_display_name\0\u{3}encrypted_bio\0\u{3}encrypted_avatar_url\0")
```

In `decodeMessage`, add after `case 4`:

```swift
      case 5: try { try decoder.decodeSingularBytesField(value: &self.profileKey) }()
      case 6: try { try decoder.decodeSingularBytesField(value: &self.encryptedDisplayName) }()
      case 7: try { try decoder.decodeSingularBytesField(value: &self.encryptedBio) }()
      case 8: try { try decoder.decodeSingularBytesField(value: &self.encryptedAvatarURL) }()
```

In `traverse`, add after the `statusText` block:

```swift
    if !self.profileKey.isEmpty {
      try visitor.visitSingularBytesField(value: self.profileKey, fieldNumber: 5)
    }
    if !self.encryptedDisplayName.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedDisplayName, fieldNumber: 6)
    }
    if !self.encryptedBio.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedBio, fieldNumber: 7)
    }
    if !self.encryptedAvatarURL.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedAvatarURL, fieldNumber: 8)
    }
```

In `==`, add before `if lhs.unknownFields`:

```swift
    if lhs.profileKey != rhs.profileKey {return false}
    if lhs.encryptedDisplayName != rhs.encryptedDisplayName {return false}
    if lhs.encryptedBio != rhs.encryptedBio {return false}
    if lhs.encryptedAvatarURL != rhs.encryptedAvatarURL {return false}
```

- [ ] **Step 6: Manually patch `contacts.pb.swift` — `MatchedContact` struct**

In `Sanchr_Contacts_MatchedContact` struct (around line 52), add after `public var phoneNumber: String = String()`:

```swift
  public var profileKey: Data = Data()
  public var encryptedDisplayName: Data = Data()
  public var encryptedBio: Data = Data()
  public var encryptedAvatarURL: Data = Data()
```

In the extension, update `_protobuf_nameMap`:

```swift
  public static let _protobuf_nameMap = SwiftProtobuf._NameMap(bytecode: "\0\u{3}user_id\0\u{3}display_name\0\u{3}avatar_url\0\u{3}status_text\0\u{3}phone_number\0\u{3}profile_key\0\u{3}encrypted_display_name\0\u{3}encrypted_bio\0\u{3}encrypted_avatar_url\0")
```

In `decodeMessage`, add after `case 5`:

```swift
      case 6: try { try decoder.decodeSingularBytesField(value: &self.profileKey) }()
      case 7: try { try decoder.decodeSingularBytesField(value: &self.encryptedDisplayName) }()
      case 8: try { try decoder.decodeSingularBytesField(value: &self.encryptedBio) }()
      case 9: try { try decoder.decodeSingularBytesField(value: &self.encryptedAvatarURL) }()
```

In `traverse`, add after the `phoneNumber` block:

```swift
    if !self.profileKey.isEmpty {
      try visitor.visitSingularBytesField(value: self.profileKey, fieldNumber: 6)
    }
    if !self.encryptedDisplayName.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedDisplayName, fieldNumber: 7)
    }
    if !self.encryptedBio.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedBio, fieldNumber: 8)
    }
    if !self.encryptedAvatarURL.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedAvatarURL, fieldNumber: 9)
    }
```

In `==`, add before `if lhs.unknownFields`:

```swift
    if lhs.profileKey != rhs.profileKey {return false}
    if lhs.encryptedDisplayName != rhs.encryptedDisplayName {return false}
    if lhs.encryptedBio != rhs.encryptedBio {return false}
    if lhs.encryptedAvatarURL != rhs.encryptedAvatarURL {return false}
```

- [ ] **Step 7: Manually patch `contacts.pb.swift` — `Contact` struct**

In `Sanchr_Contacts_Contact` struct (around line 94), add after `public var phoneNumber: String = String()`:

```swift
  public var profileKey: Data = Data()
  public var encryptedDisplayName: Data = Data()
  public var encryptedBio: Data = Data()
  public var encryptedAvatarURL: Data = Data()
```

In the extension, update `_protobuf_nameMap`:

```swift
  public static let _protobuf_nameMap = SwiftProtobuf._NameMap(bytecode: "\0\u{3}user_id\0\u{3}display_name\0\u{3}avatar_url\0\u{3}status_text\0\u{3}is_blocked\0\u{3}is_favorite\0\u{3}phone_number\0\u{3}profile_key\0\u{3}encrypted_display_name\0\u{3}encrypted_bio\0\u{3}encrypted_avatar_url\0")
```

In `decodeMessage`, add after `case 7`:

```swift
      case 8:  try { try decoder.decodeSingularBytesField(value: &self.profileKey) }()
      case 9:  try { try decoder.decodeSingularBytesField(value: &self.encryptedDisplayName) }()
      case 10: try { try decoder.decodeSingularBytesField(value: &self.encryptedBio) }()
      case 11: try { try decoder.decodeSingularBytesField(value: &self.encryptedAvatarURL) }()
```

In `traverse`, add after the `phoneNumber` block:

```swift
    if !self.profileKey.isEmpty {
      try visitor.visitSingularBytesField(value: self.profileKey, fieldNumber: 8)
    }
    if !self.encryptedDisplayName.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedDisplayName, fieldNumber: 9)
    }
    if !self.encryptedBio.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedBio, fieldNumber: 10)
    }
    if !self.encryptedAvatarURL.isEmpty {
      try visitor.visitSingularBytesField(value: self.encryptedAvatarURL, fieldNumber: 11)
    }
```

In `==`, add before `if lhs.unknownFields`:

```swift
    if lhs.profileKey != rhs.profileKey {return false}
    if lhs.encryptedDisplayName != rhs.encryptedDisplayName {return false}
    if lhs.encryptedBio != rhs.encryptedBio {return false}
    if lhs.encryptedAvatarURL != rhs.encryptedAvatarURL {return false}
```

---

- [ ] **Step 8: Build to verify**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`. If there are "value of type X has no member Y" errors, the new fields were not added to the correct struct or extension — re-read the generated file to verify placement.

- [ ] **Step 9: Run full test suite**

```bash
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | tail -5
```

- [ ] **Step 10: Commit**

```bash
git add Proto/settings.proto \
        Proto/contacts.proto \
        SanchrShared/Generated/settings.pb.swift \
        SanchrShared/Generated/contacts.pb.swift
git commit -m "feat: add encrypted profile fields to settings + contacts proto"
```

---

### Task 5: Wire encryption in UpdateProfile send path

**Files:**
- Modify: `Features/Profile/Data/ProfileDataSource.swift`
- Modify: `Features/Profile/Domain/ProfileUseCases.swift`
- Modify: `Features/Profile/Presentation/ProfileViewModel.swift`
- Modify: `Features/Profile/Presentation/ProfileView.swift`
- Create: `Tests/UnitTests/ProfileUseCasesEncryptionTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UnitTests/ProfileUseCasesEncryptionTests.swift
import XCTest
import SanchrShared
@testable import Sanchr

// MARK: - Stub

/// Captures what UpdateProfile sends to the data layer.
private final class StubProfileDataSource: ProfileDataSourceProtocol, @unchecked Sendable {
    var capturedProfileKey: Data?
    var capturedEncryptedDisplayName: Data?
    var capturedEncryptedBio: Data?
    var capturedEncryptedAvatarURL: Data?

    func updateProfile(
        name: String,
        avatarURL: String,
        status: String,
        profileKey: Data,
        encryptedDisplayName: Data,
        encryptedBio: Data,
        encryptedAvatarURL: Data
    ) async throws -> Sanchr_Settings_ProfileResponse {
        capturedProfileKey = profileKey
        capturedEncryptedDisplayName = encryptedDisplayName
        capturedEncryptedBio = encryptedBio
        capturedEncryptedAvatarURL = encryptedAvatarURL
        var response = Sanchr_Settings_ProfileResponse()
        response.displayName = name
        return response
    }

    func uploadAvatar(imageData: Data) async throws -> String { "" }
    func getProfile() async throws -> Sanchr_Settings_ProfileResponse {
        Sanchr_Settings_ProfileResponse()
    }
}

// MARK: - Tests

final class ProfileUseCasesEncryptionTests: XCTestCase {

    private func makeSUT() -> (
        sut: ProfileUseCases.UpdateProfile,
        dataSource: StubProfileDataSource,
        keychain: MockKeychainService
    ) {
        let dataSource = StubProfileDataSource()
        let keychain   = MockKeychainService()
        let sut = ProfileUseCases.UpdateProfile(
            profileDataSource: dataSource,
            profileKeyStore: ProfileKeyStore(keychain: keychain),
            profileCrypto: ProfileCryptor()
        )
        return (sut, dataSource, keychain)
    }

    func test_execute_sends32ByteProfileKey() async throws {
        let (sut, dataSource, _) = makeSUT()
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "")
        XCTAssertEqual(dataSource.capturedProfileKey?.count, 32)
    }

    func test_execute_encryptedDisplayName_isNotEqualToPlaintext() async throws {
        let (sut, dataSource, _) = makeSUT()
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "")
        let encrypted = try XCTUnwrap(dataSource.capturedEncryptedDisplayName)
        XCTAssertFalse(encrypted.isEmpty)
        XCTAssertNotEqual(encrypted, "Alice".data(using: .utf8),
                          "ciphertext must not equal the plaintext UTF-8 bytes")
    }

    func test_execute_profileKey_isStable_acrossMultipleCalls() async throws {
        let (sut, dataSource, _) = makeSUT()
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "")
        let key1 = dataSource.capturedProfileKey
        _ = try await sut.execute(name: "Bob", avatarURL: "", status: "")
        let key2 = dataSource.capturedProfileKey
        XCTAssertEqual(key1, key2, "the profile key must not rotate between calls")
    }

    func test_execute_emptyStatus_sendsEmptyEncryptedBio() async throws {
        let (sut, dataSource, _) = makeSUT()
        _ = try await sut.execute(name: "Alice", avatarURL: "", status: "")
        XCTAssertEqual(dataSource.capturedEncryptedBio, Data(),
                       "empty status must not produce ciphertext")
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/ProfileUseCasesEncryptionTests \
  2>&1 | grep -E "FAILED|PASSED|error:|ProfileUseCases"
```

Expected: Build error — `ProfileDataSourceProtocol` not yet defined.

- [ ] **Step 3: Update `ProfileDataSource.swift`**

Add the protocol at the top of the file, before the `final class ProfileDataSource`:

```swift
// MARK: - Protocol (for testability)

protocol ProfileDataSourceProtocol: AnyObject, Sendable {
    func updateProfile(
        name: String,
        avatarURL: String,
        status: String,
        profileKey: Data,
        encryptedDisplayName: Data,
        encryptedBio: Data,
        encryptedAvatarURL: Data
    ) async throws -> Sanchr_Settings_ProfileResponse

    func uploadAvatar(imageData: Data) async throws -> String
    func getProfile() async throws -> Sanchr_Settings_ProfileResponse
}
```

Make `ProfileDataSource` conform:
```swift
final class ProfileDataSource: ProfileDataSourceProtocol, @unchecked Sendable {
```

Replace the existing `updateProfile` method body with the new signature:

```swift
    func updateProfile(
        name: String,
        avatarURL: String,
        status: String,
        profileKey: Data,
        encryptedDisplayName: Data,
        encryptedBio: Data,
        encryptedAvatarURL: Data
    ) async throws -> Sanchr_Settings_ProfileResponse {
        var request = Sanchr_Settings_UpdateProfileRequest()
        request.displayName = name
        request.avatarURL = avatarURL
        request.statusText = status
        request.profileKey = profileKey
        request.encryptedDisplayName = encryptedDisplayName
        request.encryptedBio = encryptedBio
        request.encryptedAvatarURL = encryptedAvatarURL

        SanchrLogger.network.info("ProfileDataSource: updateProfile name=\(name.prefix(10))...")
        return try await settingsClient.updateProfile(request)
    }
```

- [ ] **Step 4: Update `ProfileUseCases.swift`**

Replace the entire `UpdateProfile` struct:

```swift
    /// Updates the user's profile, encrypting fields before sending.
    struct UpdateProfile: Sendable {
        private let profileDataSource: ProfileDataSourceProtocol
        private let profileKeyStore: ProfileKeyStoreProtocol
        private let profileCrypto: ProfileCryptoProtocol

        init(
            profileDataSource: ProfileDataSourceProtocol,
            profileKeyStore: ProfileKeyStoreProtocol,
            profileCrypto: ProfileCryptoProtocol
        ) {
            self.profileDataSource = profileDataSource
            self.profileKeyStore = profileKeyStore
            self.profileCrypto = profileCrypto
        }

        /// Encrypts name/bio/avatarURL with the local Profile Key, then sends
        /// both plaintext (server compat) and encrypted fields to the server.
        func execute(
            name: String,
            avatarURL: String,
            status: String
        ) async throws -> Sanchr_Settings_ProfileResponse {
            let profileKey = try profileKeyStore.ownProfileKey()

            let encryptedName = try profileCrypto.encryptField(
                name, profileKey: profileKey, field: .displayName)
            let encryptedBio: Data = status.isEmpty
                ? Data()
                : (try profileCrypto.encryptField(status, profileKey: profileKey, field: .bio))
            let encryptedAvatarURL: Data = avatarURL.isEmpty
                ? Data()
                : (try profileCrypto.encryptField(avatarURL, profileKey: profileKey, field: .avatarURL))

            return try await profileDataSource.updateProfile(
                name: name,
                avatarURL: avatarURL,
                status: status,
                profileKey: profileKey,
                encryptedDisplayName: encryptedName,
                encryptedBio: encryptedBio,
                encryptedAvatarURL: encryptedAvatarURL
            )
        }
    }
```

- [ ] **Step 5: Update `ProfileViewModel.swift`**

Replace `saveProfile(profileDataSource:sessionService:)` signature and use-case init call:

```swift
    func saveProfile(
        profileDataSource: ProfileDataSourceProtocol,
        profileKeyStore: ProfileKeyStoreProtocol,
        profileCrypto: ProfileCryptoProtocol,
        sessionService: SessionService
    ) async {
        isSaving = true
        defer { isSaving = false }

        let useCase = ProfileUseCases.UpdateProfile(
            profileDataSource: profileDataSource,
            profileKeyStore: profileKeyStore,
            profileCrypto: profileCrypto
        )

        do {
            let response = try await useCase.execute(
                name: displayName,
                avatarURL: avatarURL,
                status: statusText
            )

            // Update with server-confirmed plaintext values
            displayName = response.displayName.isEmpty ? displayName : response.displayName
            avatarURL   = response.avatarURL.isEmpty   ? avatarURL   : response.avatarURL
            statusText  = response.statusText.isEmpty  ? statusText  : response.statusText

            originalDisplayName = displayName
            originalStatusText  = statusText
            originalAvatarURL   = avatarURL

            sessionService.updateProfile(displayName: displayName, avatarURL: avatarURL)

            isEditing     = false
            errorMessage  = nil

            SanchrLogger.network.info("Profile saved successfully")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
```

- [ ] **Step 6: Update `ProfileView.swift`**

Add two computed properties just below the existing `profileDataSource` one:

```swift
    private var profileKeyStore: ProfileKeyStoreProtocol {
        ProfileKeyStore(keychain: container.keychainService)
    }

    private let profileCrypto: ProfileCryptoProtocol = ProfileCryptor()
```

Update the `saveProfile` call site (around line 184):

```swift
                            await viewModel.saveProfile(
                                profileDataSource: profileDataSource,
                                profileKeyStore: profileKeyStore,
                                profileCrypto: profileCrypto,
                                sessionService: container.sessionService
                            )
```

- [ ] **Step 7: Build to verify**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`. Common errors to fix:
- If `uploadAvatar` call site breaks: `ProfileDataSource` still satisfies `UploadAvatar` use case directly — no change needed there.
- If `saveProfile` call site in `ProfileView` has argument-count mismatch: verify Step 6 was applied.

- [ ] **Step 8: Run the new tests**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/ProfileUseCasesEncryptionTests \
  2>&1 | grep -E "FAILED|PASSED|error:|test_"
```

Expected: 4 tests **PASS**.

- [ ] **Step 9: Run full test suite**

```bash
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | tail -5
```

Expected: Same pass count + 4 new passes, 0 new failures.

- [ ] **Step 10: Commit**

```bash
git add Features/Profile/Data/ProfileDataSource.swift \
        Features/Profile/Domain/ProfileUseCases.swift \
        Features/Profile/Presentation/ProfileViewModel.swift \
        Features/Profile/Presentation/ProfileView.swift \
        Tests/UnitTests/ProfileUseCasesEncryptionTests.swift
git commit -m "feat: encrypt profile fields in UpdateProfile send path"
```

---

### Task 6: Wire decryption in fetchContacts receive path

**Files:**
- Modify: `Shared/Repositories/ContactRepository.swift`
- Modify: `App/DependencyContainer.swift`
- Create: `Tests/UnitTests/ContactRepositoryDecryptTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/UnitTests/ContactRepositoryDecryptTests.swift
import XCTest
import GRPC
import NIOCore
import NIOEmbedded
import SanchrShared
@testable import Sanchr

// MARK: - Spy contacts service

/// Wraps a FakeChannel so pre-registered responses are dispatched correctly
/// through the protocol extension's `makeAsyncUnaryCall` path.
@available(swift, deprecated: 5.6)
private final class SpyContactsService: Sanchr_Contacts_ContactServiceAsyncClientProtocol,
    @unchecked Sendable
{
    let channel: GRPCChannel
    var defaultCallOptions: CallOptions = CallOptions()
    var interceptors: Sanchr_Contacts_ContactServiceClientInterceptorFactoryProtocol? = nil

    let fakeChannel: FakeChannel

    init() {
        let fc = FakeChannel()
        self.fakeChannel = fc
        self.channel = fc
    }

    func registerGetContactsResponse(_ response: Sanchr_Contacts_GetContactsResponse) {
        let fake = fakeChannel.makeFakeUnaryResponse(
            path: Sanchr_Contacts_ContactServiceClientMetadata.Methods.getContacts.path,
            requestHandler: { _ in }
        ) as FakeUnaryResponse<Sanchr_Contacts_GetContactsRequest, Sanchr_Contacts_GetContactsResponse>
        try? fake.sendMessage(response)
    }

    // Required make*Call stubs — not invoked through the protocol extension default.
    func makeSyncContactsCall(_ r: Sanchr_Contacts_SyncContactsRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Contacts_SyncContactsRequest, Sanchr_Contacts_SyncContactsResponse>
    { fatalError("not used in ContactRepositoryDecryptTests") }

    func makeGetContactsCall(_ r: Sanchr_Contacts_GetContactsRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Contacts_GetContactsRequest, Sanchr_Contacts_GetContactsResponse>
    { fatalError("not used in ContactRepositoryDecryptTests") }

    func makeBlockContactCall(_ r: Sanchr_Contacts_BlockContactRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Contacts_BlockContactRequest, Sanchr_Contacts_BlockContactResponse>
    { fatalError("not used in ContactRepositoryDecryptTests") }

    func makeUnblockContactCall(_ r: Sanchr_Contacts_UnblockContactRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Contacts_UnblockContactRequest, Sanchr_Contacts_UnblockContactResponse>
    { fatalError("not used in ContactRepositoryDecryptTests") }

    func makeGetBlockedListCall(_ r: Sanchr_Contacts_GetBlockedListRequest, callOptions: CallOptions?)
        -> GRPCAsyncUnaryCall<Sanchr_Contacts_GetBlockedListRequest, Sanchr_Contacts_GetBlockedListResponse>
    { fatalError("not used in ContactRepositoryDecryptTests") }
}

// MARK: - Stub GRPC client (contacts path only)

private final class StubGRPCClientForContacts: GRPCClientProtocol, @unchecked Sendable {
    let contactService: Sanchr_Contacts_ContactServiceAsyncClientProtocol

    init(contactService: Sanchr_Contacts_ContactServiceAsyncClientProtocol) {
        self.contactService = contactService
    }

    func connect() async throws {}
    func disconnect() async throws {}
    var isConnected: Bool { false }

    var authService: Sanchr_Auth_AuthServiceAsyncClientProtocol
        { fatalError("not used") }
    var messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol
        { fatalError("not used") }
    var keyService: Sanchr_Keys_KeyServiceAsyncClientProtocol
        { fatalError("not used") }
    var mediaService: Sanchr_Media_MediaServiceAsyncClientProtocol
        { fatalError("not used") }
    var settingsService: Sanchr_Settings_SettingsServiceAsyncClientProtocol
        { fatalError("not used") }
    var notificationService: Sanchr_Notifications_NotificationServiceAsyncClientProtocol
        { fatalError("not used") }
    var vaultService: Sanchr_Vault_VaultServiceAsyncClientProtocol
        { fatalError("not used") }
    var backupService: Sanchr_Backup_BackupServiceAsyncClientProtocol
        { fatalError("not used") }
    var discoveryService: Sanchr_Discovery_DiscoveryServiceAsyncClientProtocol
        { fatalError("not used") }
    var callSignalingService: Sanchr_Calling_CallSignalingServiceAsyncClientProtocol
        { fatalError("not used") }
}

// MARK: - Stub local database (only saveContact needed)

private final class StubLocalDatabaseForContacts: LocalDatabaseProtocol, @unchecked Sendable {
    func saveContact(_ user: User) async throws { /* no-op — not the focus of these tests */ }

    // All other methods: fatalError to catch accidental calls.
    func saveMessage(_ m: Message) async throws { fatalError() }
    func saveIncomingMessageAndQueueAck(_ m: Message) async throws { fatalError() }
    func fetchMessages(conversationId: String, before: Date?, limit: Int) async throws -> [Message] { fatalError() }
    func deleteMessage(id: String) async throws { fatalError() }
    func markConversationAsRead(conversationId: String, upToMessageId: String) async throws { fatalError() }
    func updateMessageStatus(id: String, status: Message.DeliveryStatus) async throws { fatalError() }
    func fetchPendingMessageAcks(limit: Int) async throws -> [PendingMessageAck] { fatalError() }
    func deletePendingMessageAcks(_ acks: [PendingMessageAck]) async throws { fatalError() }
    func searchMessages(conversationId: String, query: String) async throws -> [Message] { fatalError() }
    func saveConversation(_ c: Conversation) async throws { fatalError() }
    func fetchConversation(id: String) async throws -> Conversation? { fatalError() }
    func fetchConversations() async throws -> [Conversation] { fatalError() }
    func deleteConversation(id: String) async throws { fatalError() }
    func fetchContacts() async throws -> [User] { fatalError() }
    func searchContacts(query: String) async throws -> [User] { fatalError() }
    func saveVaultItem(_ item: VaultItem) async throws { fatalError() }
    func fetchVaultItems() async throws -> [VaultItem] { fatalError() }
    func fetchAllVaultItems() async throws -> [VaultItem] { fatalError() }
    func deleteVaultItem(id: String) async throws { fatalError() }
    func saveAccessKeyEntry(_ e: AccessKeyEntry) async throws { fatalError() }
    func fetchAccessKeyEntry(mediaId: String) async throws -> AccessKeyEntry? { fatalError() }
    func updateAccessKeyEntryLastAccessed(mediaId: String, lastAccessedAt: Date) async throws { fatalError() }
    func deleteAccessKeyEntry(mediaId: String) async throws { fatalError() }
    func purgeAccessKeyEntries(olderThan: Date) async throws -> Int { fatalError() }
    func deleteAllAccessKeyEntries() async throws { fatalError() }
    func fetchAppearanceOverride(conversationId: String) async throws -> AppearanceOverride? { fatalError() }
    func setAppearanceOverride(_ o: AppearanceOverride, for conversationId: String) async throws { fatalError() }
    func clearAppearanceOverride(conversationId: String) async throws { fatalError() }
    func fetchVaultPolicy(conversationId: String) async throws -> ChatVaultPolicy? { fatalError() }
    func setVaultPolicy(_ p: ChatVaultPolicy, for conversationId: String) async throws { fatalError() }
}

// MARK: - Tests

final class ContactRepositoryDecryptTests: XCTestCase {
    private let crypto = ProfileCryptor()
    private let profileKey = Data(repeating: 0xAB, count: 32)

    private func makeSUT(contactsService: SpyContactsService) -> ContactRepositoryImpl {
        ContactRepositoryImpl(
            grpcClient: StubGRPCClientForContacts(contactService: contactsService),
            localDatabase: StubLocalDatabaseForContacts(),
            profileKeyStore: ProfileKeyStore(keychain: MockKeychainService()),
            profileCrypto: crypto
        )
    }

    func test_fetchContacts_withProfileKey_decryptsDisplayName() async throws {
        // Arrange: encrypt "Alice" with the known profile key
        let encryptedName = try crypto.encryptField("Alice", profileKey: profileKey, field: .displayName)

        var contact = Sanchr_Contacts_Contact()
        contact.userID       = "user-1"
        contact.phoneNumber  = "+15555555555"
        contact.displayName  = "REDACTED"       // plaintext the server would normally send
        contact.profileKey   = profileKey
        contact.encryptedDisplayName = encryptedName

        var response = Sanchr_Contacts_GetContactsResponse()
        response.contacts = [contact]

        let service = SpyContactsService()
        service.registerGetContactsResponse(response)
        let sut = makeSUT(contactsService: service)

        // Act
        let users = try await sut.fetchContacts()

        // Assert
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[0].displayName, "Alice",
                       "should use decrypted value, not server-provided plaintext 'REDACTED'")
    }

    func test_fetchContacts_noProfileKey_usesPlaintext() async throws {
        // Arrange: contact with no profile key — should fall back to plaintext
        var contact = Sanchr_Contacts_Contact()
        contact.userID      = "user-2"
        contact.phoneNumber = "+15551234567"
        contact.displayName = "Bob"
        // profileKey is empty (default Data())

        var response = Sanchr_Contacts_GetContactsResponse()
        response.contacts = [contact]

        let service = SpyContactsService()
        service.registerGetContactsResponse(response)
        let sut = makeSUT(contactsService: service)

        // Act
        let users = try await sut.fetchContacts()

        // Assert
        XCTAssertEqual(users[0].displayName, "Bob",
                       "should use plaintext displayName when no profileKey is present")
    }

    func test_fetchContacts_decryptionFails_fallsBackToPlaintext() async throws {
        // Arrange: wrong profile key → decryption will throw → should fall back gracefully
        let wrongKey = Data(repeating: 0xFF, count: 32)
        let encryptedWithCorrectKey = try crypto.encryptField("Alice", profileKey: profileKey, field: .displayName)

        var contact = Sanchr_Contacts_Contact()
        contact.userID       = "user-3"
        contact.phoneNumber  = "+15559876543"
        contact.displayName  = "Fallback"
        contact.profileKey   = wrongKey  // key that won't decrypt the ciphertext
        contact.encryptedDisplayName = encryptedWithCorrectKey

        var response = Sanchr_Contacts_GetContactsResponse()
        response.contacts = [contact]

        let service = SpyContactsService()
        service.registerGetContactsResponse(response)
        let sut = makeSUT(contactsService: service)

        // Act — must not throw
        let users = try await sut.fetchContacts()

        // Assert: graceful fallback to plaintext
        XCTAssertEqual(users[0].displayName, "Fallback",
                       "decryption failure must fall back to plaintext without throwing")
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/ContactRepositoryDecryptTests \
  2>&1 | grep -E "FAILED|PASSED|error:|ContactRepository"
```

Expected: Build error — `ContactRepositoryImpl` init does not yet accept `profileKeyStore`/`profileCrypto`.

- [ ] **Step 3: Update `ContactRepository.swift`**

Add `profileKeyStore` and `profileCrypto` to `ContactRepositoryImpl`:

```swift
final class ContactRepositoryImpl: ContactRepositoryProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol
    private let profileKeyStore: ProfileKeyStoreProtocol
    private let profileCrypto: ProfileCryptoProtocol

    init(
        grpcClient: GRPCClientProtocol,
        localDatabase: LocalDatabaseProtocol,
        profileKeyStore: ProfileKeyStoreProtocol,
        profileCrypto: ProfileCryptoProtocol
    ) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
        self.profileKeyStore = profileKeyStore
        self.profileCrypto = profileCrypto
    }
```

Add a private helper that decrypts a single field, falling back to `nil` on any error:

```swift
    /// Attempts to decrypt `ciphertext` with `profileKey` for `field`.
    /// Returns `nil` (not the plaintext fallback) on failure — callers decide the fallback.
    private func tryDecrypt(
        _ ciphertext: Data,
        profileKey: Data,
        field: ProfileField
    ) -> String? {
        guard !ciphertext.isEmpty else { return nil }
        return try? profileCrypto.decryptField(ciphertext, profileKey: profileKey, field: field)
    }
```

Replace the `fetchContacts()` contacts-mapping block:

```swift
    func fetchContacts() async throws -> [User] {
        SanchrLogger.sync.info("Fetching contacts from server")

        let request = Sanchr_Contacts_GetContactsRequest()
        let response = try await grpcClient.contactService.getContacts(request)

        let users = response.contacts.map { contact -> User in
            var displayName = contact.displayName
            var bio: String? = contact.statusText.isEmpty ? nil : contact.statusText
            var avatarURL: URL? = URL(string: contact.avatarURL)

            if !contact.profileKey.isEmpty {
                // Persist the contact's Profile Key for future local decryption needs.
                try? profileKeyStore.saveContactProfileKey(contact.profileKey, forUserId: contact.userID)

                if let decrypted = tryDecrypt(contact.encryptedDisplayName,
                                              profileKey: contact.profileKey, field: .displayName) {
                    displayName = decrypted
                }
                if let decrypted = tryDecrypt(contact.encryptedBio,
                                              profileKey: contact.profileKey, field: .bio) {
                    bio = decrypted
                }
                if let decrypted = tryDecrypt(contact.encryptedAvatarURL,
                                              profileKey: contact.profileKey, field: .avatarURL) {
                    avatarURL = URL(string: decrypted)
                }
            }

            return User(
                id: contact.userID,
                phoneNumber: contact.phoneNumber,
                displayName: displayName,
                avatarURL: avatarURL,
                bio: bio,
                isVerified: false,
                lastSeen: nil,
                identityKeyFingerprint: nil,
                status: .offline
            )
        }

        for user in users {
            try? await localDatabase.saveContact(user)
        }

        return users
    }
```

Replace the `syncDeviceContacts()` matches-mapping block the same way (using `MatchedContact` fields):

```swift
    func syncDeviceContacts(phoneNumbers: [String]) async throws -> [User] {
        SanchrLogger.sync.info("Syncing \(phoneNumbers.count) device contacts")

        let hashes = phoneNumbers.map { phone -> Data in
            let normalized = phone.replacingOccurrences(of: "[^0-9+]", with: "", options: .regularExpression)
            return Data(SHA256.hash(data: Data(normalized.utf8)))
        }

        var request = Sanchr_Contacts_SyncContactsRequest()
        request.phoneHashes = hashes

        let response = try await grpcClient.contactService.syncContacts(request)

        let matchedUsers = response.matches.map { match -> User in
            var displayName = match.displayName
            var bio: String? = match.statusText.isEmpty ? nil : match.statusText
            var avatarURL: URL? = URL(string: match.avatarURL)

            if !match.profileKey.isEmpty {
                try? profileKeyStore.saveContactProfileKey(match.profileKey, forUserId: match.userID)

                if let decrypted = tryDecrypt(match.encryptedDisplayName,
                                              profileKey: match.profileKey, field: .displayName) {
                    displayName = decrypted
                }
                if let decrypted = tryDecrypt(match.encryptedBio,
                                              profileKey: match.profileKey, field: .bio) {
                    bio = decrypted
                }
                if let decrypted = tryDecrypt(match.encryptedAvatarURL,
                                              profileKey: match.profileKey, field: .avatarURL) {
                    avatarURL = URL(string: decrypted)
                }
            }

            return User(
                id: match.userID,
                phoneNumber: match.phoneNumber,
                displayName: displayName,
                avatarURL: avatarURL,
                bio: bio,
                isVerified: false,
                lastSeen: nil,
                identityKeyFingerprint: nil,
                status: .offline
            )
        }

        for user in matchedUsers {
            try? await localDatabase.saveContact(user)
        }

        SanchrLogger.sync.info("Found \(matchedUsers.count) Sanchr users from device contacts")
        return matchedUsers
    }
```

- [ ] **Step 4: Update `DependencyContainer.swift`**

Add two lazy properties near the existing `keychainService` property (around line 10):

```swift
    @ObservationIgnored lazy var profileKeyStore: ProfileKeyStoreProtocol = ProfileKeyStore(
        keychain: keychainService
    )

    @ObservationIgnored lazy var profileCrypto: ProfileCryptoProtocol = ProfileCryptor()
```

Update the `contactRepository` lazy property to pass the new deps:

```swift
    @ObservationIgnored lazy var contactRepository: ContactRepositoryProtocol =
        ContactRepositoryImpl(
            grpcClient: grpcClient,
            localDatabase: localDatabase,
            profileKeyStore: profileKeyStore,
            profileCrypto: profileCrypto
        )
```

- [ ] **Step 5: Build to verify**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild build \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

Expected: `Build succeeded`.

- [ ] **Step 6: Run the new tests**

```bash
cd /Users/soorajpandey/Projects/zynclave/sanchr/ios/Sanchr-iOS
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SanchrTests/ContactRepositoryDecryptTests \
  2>&1 | grep -E "FAILED|PASSED|error:|test_"
```

Expected: 3 tests **PASS**.

- [ ] **Step 7: Run full test suite**

```bash
xcodebuild test \
  -scheme Sanchr \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | tail -5
```

Expected: Same total + 3 new passes, 0 new failures.

- [ ] **Step 8: Commit**

```bash
git add Shared/Repositories/ContactRepository.swift \
        App/DependencyContainer.swift \
        Tests/UnitTests/ContactRepositoryDecryptTests.swift
git commit -m "feat: decrypt encrypted profile fields in fetchContacts + syncDeviceContacts"
```

---

## Self-Review

**Spec coverage:**
- ✅ Own Profile Key generated and persisted in Keychain → `ProfileKeyStore.ownProfileKey()`
- ✅ Per-field HKDF-SHA256 subkey derivation → `ProfileCryptor.deriveFieldKey`
- ✅ AES-256-GCM encrypt on send → `ProfileUseCases.UpdateProfile.execute()`
- ✅ Both plaintext + encrypted fields sent (backward-compatible with old server) → `ProfileDataSource.updateProfile`
- ✅ Contact profile keys stored on receive → `ContactRepositoryImpl.fetchContacts` + `syncDeviceContacts`
- ✅ Decryption with graceful plaintext fallback → `tryDecrypt` helper
- ✅ DB migration preserves existing rows → migration `v8_user_profile_key` (nullable blob)
- ✅ Proto field additions (settings + contacts) with correct field numbers

**Type consistency check:**
- `ProfileField` enum is used in both `ProfileCryptor` and `ContactRepositoryImpl` — same type ✅
- `ProfileKeyStoreProtocol.ownProfileKey()` called in `UpdateProfile.execute()` → same signature ✅
- `ProfileDataSourceProtocol` defined in `ProfileDataSource.swift`, conforming class + test stub both implement all three methods ✅
- `ContactRepositoryImpl.init` takes `ProfileKeyStoreProtocol` + `ProfileCryptoProtocol` in Step 3; `DependencyContainer` provides `profileKeyStore: ProfileKeyStoreProtocol` and `profileCrypto: ProfileCryptoProtocol` in Step 4 ✅

**No placeholders:** All steps contain runnable code with exact file paths and test commands. ✅

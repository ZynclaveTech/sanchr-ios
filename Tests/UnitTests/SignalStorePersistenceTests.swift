import XCTest
import LibSignalClient
import SanchrShared

@testable import Sanchr

final class SignalStorePersistenceTests: XCTestCase {
    private let fileManager = FileManager.default

    func testIdentityStoreRecreatesDirectoryBeforePersistingTrustStore() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }

        let userId = UUID().uuidString
        let keychain = MockKeychainService()
        let store = SanchrIdentityKeyStore(
            userId: userId,
            keychain: keychain,
            fileManager: fileManager,
            baseDirectory: root
        )

        let signalStoreRoot = root.appendingPathComponent("SignalStore/\(userId)", isDirectory: true)
        try? fileManager.removeItem(at: signalStoreRoot)

        let address = try ProtocolAddress(name: "peer", deviceId: 1)
        let identity = IdentityKeyPair.generate().identityKey
        _ = try store.saveIdentity(identity, for: address, context: LibSignalClient.NullContext())

        let persisted = signalStoreRoot.appendingPathComponent("trusted_identities.bin")
        XCTAssertTrue(waitForFile(at: persisted), "trusted_identities.bin should be recreated after the directory is deleted")
    }

    func testPreKeyStoreRecreatesDirectoryBeforePersistingPreKey() throws {
        let root = makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }

        let userId = UUID().uuidString
        let store = SanchrPreKeyStore(
            userId: userId,
            fileManager: fileManager,
            baseDirectory: root
        )

        let preKeyDirectory = root.appendingPathComponent("SignalStore/\(userId)/prekeys", isDirectory: true)
        try? fileManager.removeItem(at: preKeyDirectory)

        let record = try PreKeyRecord(id: 1, privateKey: PrivateKey.generate())
        try store.storePreKey(record, id: 1, context: LibSignalClient.NullContext())

        let persisted = preKeyDirectory.appendingPathComponent("1.prekey")
        XCTAssertTrue(fileManager.fileExists(atPath: persisted.path), "prekey file should be recreated after the directory is deleted")
    }

    private func makeTemporaryRoot() -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForFile(at url: URL, timeout: TimeInterval = 1.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fileManager.fileExists(atPath: url.path) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return fileManager.fileExists(atPath: url.path)
    }
}

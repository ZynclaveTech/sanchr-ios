import XCTest
import SanchrShared
@testable import Sanchr

final class ChatVaultPolicyMirrorTests: XCTestCase {

    func test_writeThenRead_returnsValue() {
        let mirror = ChatVaultPolicyMirror()
        let policy = ChatVaultPolicy(
            conversationId: "c1",
            autoVaultIncoming: true,
            viewOnceOutgoing: false,
            screenshotProtection: true
        )
        mirror.write(policy)
        XCTAssertEqual(mirror.policy(for: "c1"), policy)
    }

    func test_unknownConversationId_returnsNil() {
        let mirror = ChatVaultPolicyMirror()
        XCTAssertNil(mirror.policy(for: "nope"))
    }

    func test_remove_clearsValue() {
        let mirror = ChatVaultPolicyMirror()
        mirror.write(ChatVaultPolicy(
            conversationId: "c1",
            autoVaultIncoming: true,
            viewOnceOutgoing: false,
            screenshotProtection: false
        ))
        mirror.remove(conversationId: "c1")
        XCTAssertNil(mirror.policy(for: "c1"))
    }

    func test_concurrentWritesAndReads_doNotCrash() async {
        let mirror = ChatVaultPolicyMirror()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    mirror.write(ChatVaultPolicy(
                        conversationId: "c\(i % 5)",
                        autoVaultIncoming: i.isMultiple(of: 2),
                        viewOnceOutgoing: false,
                        screenshotProtection: false
                    ))
                    _ = mirror.policy(for: "c\(i % 5)")
                }
            }
        }
        // Survives — that's the assertion. NSLock-protected storage
        // should never crash under concurrent writes/reads.
    }
}

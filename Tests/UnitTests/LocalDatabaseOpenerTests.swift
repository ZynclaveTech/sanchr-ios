import Foundation
import SanchrShared
import XCTest

@testable import Sanchr

/// The database is opened once, off the main thread where possible, and a
/// caller that arrives mid-open joins it instead of opening a second copy.
final class LocalDatabaseOpenerTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeOpener(delayMicroseconds: UInt32 = 0, counter: Counter) -> LocalDatabaseOpener {
        LocalDatabaseOpener {
            _ = counter.increment()
            if delayMicroseconds > 0 { usleep(delayMicroseconds) }
            return .failure(.databaseError(reason: "test"))
        }
    }

    func testConcurrentCallersShareOneOpen() async {
        let counter = Counter()
        let opener = makeOpener(delayMicroseconds: 150_000, counter: counter)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = opener.result() }
            }
        }

        XCTAssertEqual(counter.count, 1)
    }

    func testAPrewarmedOpenIsReused() async throws {
        let counter = Counter()
        let opener = makeOpener(delayMicroseconds: 50_000, counter: counter)

        opener.prewarm()
        try await Task.sleep(for: .milliseconds(200))
        _ = opener.result()

        XCTAssertEqual(counter.count, 1)
    }

    /// After the database files and key are destroyed the next open must be a
    /// real one.
    func testResetOpensAgain() {
        let counter = Counter()
        let opener = makeOpener(counter: counter)
        _ = opener.result()
        opener.reset()
        _ = opener.result()
        XCTAssertEqual(counter.count, 2)
    }

    // MARK: - Wiring

    func testTheContainerPrewarmsAndResetsTheOpener() throws {
        let container = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("App/DependencyContainer.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(container.contains("localDatabaseOpener.prewarm()"))
        let reset = try XCTUnwrap(container.range(of: "func resetLocalSecrets() async {"))
        XCTAssertTrue(String(container[reset.upperBound...].prefix(900)).contains("localDatabaseOpener.reset()"))
    }
}

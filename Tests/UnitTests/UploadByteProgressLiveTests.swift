import Foundation
import Network
import XCTest
@testable import SanchrShared

/// Proves the transport end of upload progress with a real request: the S3 PUT
/// runs on `URLSession.shared` with a per-task delegate, and this checks that
/// such a delegate actually receives byte callbacks during a multi-megabyte
/// upload to a local server, rather than only at completion.
final class UploadByteProgressLiveTests: XCTestCase {
    /// Minimal HTTP server: reads the request until the declared body length
    /// has arrived, then answers 200.
    private final class SlowSink: @unchecked Sendable {
        let listener: NWListener
        var port: UInt16 { listener.port!.rawValue }
        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                self?.drain(connection, received: 0, expected: nil)
            }
            listener.start(queue: .global())
            XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        }
        private func drain(_ connection: NWConnection, received: Int, expected: Int?) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
                guard let self, error == nil, let data else { return }
                var expected = expected
                var received = received
                if expected == nil,
                   let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
                   let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8),
                   let lengthLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                   let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) {
                    expected = length
                    received += data.count - headerEnd.upperBound
                } else {
                    received += data.count
                }
                if let expected, received >= expected {
                    connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                    completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    // Read slowly so the client has to report progress in steps.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                        self.drain(connection, received: received, expected: expected)
                    }
                }
            }
        }
    }

    func testSharedSessionTaskDelegateReportsBytesDuringUpload() async throws {
        let server = try SlowSink()
        final class Sink: @unchecked Sendable {
            var seen: [Double] = []; let lock = NSLock()
            func snapshot() -> [Double] { lock.lock(); defer { lock.unlock() }; return seen }
        }
        let sink = Sink()
        let delegate = UploadProgressDelegate { fraction in
            sink.lock.lock(); sink.seen.append(fraction); sink.lock.unlock()
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/upload")!)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let body = Data(count: 6 * 1024 * 1024)
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")

        let (_, response) = try await URLSession.shared.upload(for: request, from: body, delegate: delegate)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let seen = sink.snapshot()
        XCTAssertGreaterThanOrEqual(seen.count, 3, "expected intermediate byte progress, got \(seen)")
        XCTAssertEqual(seen.last, 1.0)
        XCTAssertEqual(seen, seen.sorted(), "monotonic")
        XCTAssertTrue(seen.contains { $0 > 0 && $0 < 1 }, "at least one mid-upload fraction: \(seen)")
    }
}

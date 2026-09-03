import Foundation
import os

/// The access token and device id the gRPC interceptor stamps on every
/// call, read from the Keychain once and then served from memory.
///
/// The interceptor runs on a NIO event-loop thread and used to make two
/// synchronous Keychain queries per RPC there. The session invalidates the
/// cache whenever it writes or deletes credentials, so the next call
/// reloads. A missing token is never cached: before sign-in every
/// unauthenticated call would otherwise pin "no token" until the first
/// invalidation.
public final class AuthHeaderCache: @unchecked Sendable {
    public struct Headers: Equatable, Sendable {
        public let accessToken: String?
        public let deviceId: String?
    }

    private struct State {
        var loaded = false
        var headers = Headers(accessToken: nil, deviceId: nil)
    }

    private let readAccessToken: @Sendable () throws -> String?
    private let readDeviceId: @Sendable () throws -> String?
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        readAccessToken: @escaping @Sendable () throws -> String?,
        readDeviceId: @escaping @Sendable () throws -> String?
    ) {
        self.readAccessToken = readAccessToken
        self.readDeviceId = readDeviceId
    }

    public convenience init(secureStorage: SecureStorageProtocol) {
        self.init(
            readAccessToken: { try secureStorage.readAccessToken() },
            readDeviceId: { try secureStorage.readDeviceId() }
        )
    }

    /// The current headers, loading from storage on a miss.
    public func headers() -> Headers {
        if let cached = state.withLock({ $0.loaded && $0.headers.accessToken != nil ? $0.headers : nil }) {
            return cached
        }
        let fresh = Headers(
            accessToken: (try? readAccessToken()) ?? nil,
            deviceId: (try? readDeviceId()) ?? nil
        )
        state.withLock {
            $0.loaded = true
            $0.headers = fresh
        }
        return fresh
    }

    /// Forget the cached values; the next call reloads from storage.
    public func invalidate() {
        state.withLock { $0 = State() }
    }
}

import Foundation
import GRPC

// MARK: - Error Type

/// Errors specific to sealed sender operations.
public enum SealedSenderError: Error, Sendable {
    case certificateExpired
    case certificateFetchFailed(underlying: Error)
    case deliveryTokenPoolEmpty
    case deliveryTokenFetchFailed(underlying: Error)
    case innerPayloadEncodeFailed(underlying: Error)
    case innerPayloadDecodeFailed(underlying: Error)
    case invalidInnerPayload
}

// MARK: - InnerPayload

/// The plaintext payload embedded inside a sealed sender envelope.
///
/// Carries the conversation context and content so the recipient can
/// attribute the decrypted message without relying on server metadata.
public struct InnerPayload: Codable, Sendable {
    public let v: Int
    public let conversationId: String
    public let messageId: String?
    public let contentType: String
    public let content: Data
    public let isSync: Bool
    /// Disappearing-message lifetime in seconds, or nil when the conversation has
    /// no timer set.
    ///
    /// This rides inside the sealed envelope rather than on the request, because
    /// `SendSealedMessageRequest` has no TTL field and the server must not learn
    /// the timer anyway. Optional so that payloads from clients predating this
    /// field still decode, and so older clients ignore the extra key.
    public let expiresAfterSecs: Int64?

    enum CodingKeys: String, CodingKey {
        case v
        case conversationId = "conversation_id"
        case messageId = "message_id"
        case contentType = "content_type"
        case content
        case isSync = "is_sync"
        case expiresAfterSecs = "expires_after_secs"
    }

    public init(
        v: Int = 1,
        conversationId: String,
        messageId: String? = nil,
        contentType: String,
        content: Data,
        isSync: Bool,
        expiresAfterSecs: Int64? = nil
    ) {
        self.expiresAfterSecs = expiresAfterSecs
        self.v = v
        self.conversationId = conversationId
        self.messageId = messageId
        self.contentType = contentType
        self.content = content
        self.isSync = isSync
    }
}

// MARK: - Protocol

/// Manages sealed sender operations: sender certificates, delivery tokens,
/// and inner payload encoding/decoding.
public protocol SealedSenderManagerProtocol: Sendable {
    /// Returns a valid sender certificate, fetching from the server if the
    /// cached copy is within 1 hour of expiry.
    func getSenderCertificate() async throws -> Data

    /// Pops a single delivery token from the local pool, replenishing
    /// from the server if the pool is empty.
    func acquireDeliveryToken() async throws -> Data

    /// Constructs and JSON-encodes an `InnerPayload` for sealed sender transmission.
    func encodeInnerPayload(
        conversationId: String,
        messageId: String?,
        contentType: String,
        content: Data,
        isSync: Bool,
        expiresAfterSecs: Int64?
    ) throws -> Data

    /// Decodes a JSON-encoded `InnerPayload`.
    func decodeInnerPayload(_ data: Data) throws -> InnerPayload

    /// Returns `true` if `data` appears to be a valid JSON-encoded `InnerPayload`.
    static func isInnerPayload(_ data: Data) -> Bool

    /// Tops up the delivery token pool if it has fallen below the low-water mark.
    func replenishIfNeeded() async
}

// MARK: - Implementation

/// Sealed sender manager backed by gRPC RPCs and Keychain storage.
///
/// Thread safety:
/// - The delivery token pool and certificate cache are guarded by `NSLock`
///   via synchronous helper methods that never cross an `await` boundary.
///
/// Follows the same `@unchecked Sendable` pattern as `SignalSessionManager`.
public final class SealedSenderManager: SealedSenderManagerProtocol, @unchecked Sendable {

    // MARK: - Constants

    /// Batch size when fetching delivery tokens from the server.
    private static let tokenBatchSize: Int32 = 50

    /// Low-water mark: replenish when pool drops below this count.
    private static let tokenLowWaterMark = 10

    /// Minimum remaining validity before forcing a certificate refresh (1 hour).
    private static let certRefreshMarginSeconds: TimeInterval = 3600

    /// Server trust-root public key — 33 bytes, type-prefixed Curve25519
    /// (`[0x05, ...32 bytes...]`) — derived from the backend's
    /// `auth.sealed_sender_key` via
    /// `cargo run -p sanchr-server-crypto --bin print-trust-root`.
    ///
    /// Currently unused in iOS's send path (which uses Signal-encrypt +
    /// delivery tokens rather than libsignal sealed-sender envelopes — see
    /// `EncryptedMessageSendingClient.sendSealedMessage` line 225-229 where
    /// the cert fetch result is discarded). Kept here so the constant is in
    /// place when iOS migrates to libsignal sealed-sender, and as parity
    /// with the Android `BuildConfig.SEALED_SENDER_TRUST_ROOT` baked in by
    /// `core/crypto/build.gradle.kts`. Rotation: when the backend's
    /// `sealed-sender-key` changes, regenerate this value alongside the
    /// Android default.
    static let serverTrustRootBytes: [UInt8] = [
        0x05, 0x91, 0x44, 0x97, 0x06, 0x98, 0x51, 0x42,
        0xe7, 0xc8, 0xc1, 0x5f, 0x0e, 0xb4, 0x00, 0x76,
        0xe3, 0x46, 0xce, 0x5f, 0x57, 0x30, 0x63, 0x68,
        0xfd, 0xb0, 0x88, 0xb8, 0xfd, 0x8d, 0xf0, 0x34,
        0x36,
    ]

    // MARK: - Keychain Keys

    private enum KeychainKeys {
        static let deliveryTokenPool = "io.sanchr.sealed_sender.delivery_tokens"
    }

    // MARK: - Dependencies

    private let messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol
    private let keychain: KeychainServiceProtocol

    // MARK: - State (guarded by `lock`)

    private let lock = NSLock()

    /// In-memory cache of the current sender certificate (raw DER bytes).
    /// `nil` if never fetched.
    private var cachedCertificate: Data?

    /// Expiration date of the cached certificate.
    private var cachedCertificateExpiry: Date = .distantPast

    /// In-memory delivery token pool. Persisted to Keychain between sessions.
    private var tokenPool: [Data] = []

    /// Whether the token pool has been loaded from Keychain in this session.
    private var tokenPoolLoaded = false

    /// Whether a `fetchAndStoreTokens` call is already in-flight.
    /// Prevents concurrent token-fetch RPCs when multiple callers (e.g.
    /// a jittered read receipt and a P2P presence send) race to refill
    /// an empty pool at the same moment.
    private var isFetchingTokens = false

    // MARK: - Init

    public init(
        messagingService: Sanchr_Messaging_MessagingServiceAsyncClientProtocol,
        keychain: KeychainServiceProtocol
    ) {
        self.messagingService = messagingService
        self.keychain = keychain
        SanchrLogger.crypto.info("SealedSenderManager initialized")
    }

    // MARK: - Sender Certificate

    public func getSenderCertificate() async throws -> Data {
        // Fast path: return cached cert if still valid with margin.
        if let cached = getCachedCertificateIfValid() {
            return cached
        }

        // Slow path: fetch from server.
        let response: Sanchr_Messaging_SenderCertificateResponse
        do {
            let request = Sanchr_Messaging_SenderCertificateRequest()
            response = try await messagingService.getSenderCertificate(request)
        } catch {
            SanchrLogger.crypto.error(
                "GetSenderCertificate RPC failed: \(error.localizedDescription)")
            throw SealedSenderError.certificateFetchFailed(underlying: error)
        }

        let certData = response.certificate
        let expiry = Date(timeIntervalSince1970: TimeInterval(response.expiration))
        storeCertificate(certData, expiry: expiry)

        SanchrLogger.crypto.info(
            "Sender certificate refreshed, expires \(expiry)")
        return certData
    }

    // MARK: - Delivery Tokens

    public func acquireDeliveryToken() async throws -> Data {
        loadPoolFromKeychainIfNeeded()

        // Try to pop from pool.
        if let result = popToken() {
            persistPoolToKeychain()
            SanchrLogger.crypto.debug(
                "Acquired delivery token, \(result.remaining) remaining in pool")
            return result.token
        }

        // Pool empty — fetch a fresh batch, deduplicating concurrent callers.
        try await fetchAndStoreTokens()

        guard let result = popToken() else {
            throw SealedSenderError.deliveryTokenPoolEmpty
        }
        persistPoolToKeychain()

        SanchrLogger.crypto.debug(
            "Acquired delivery token after refill, \(result.remaining) remaining")
        return result.token
    }

    public func replenishIfNeeded() async {
        loadPoolFromKeychainIfNeeded()

        let count = poolCount()
        guard count < Self.tokenLowWaterMark else { return }

        // Skip if another caller is already fetching.
        guard !isFetchingTokensFlag() else {
            SanchrLogger.crypto.debug("Skipping replenish — fetch already in-flight")
            return
        }

        SanchrLogger.crypto.info(
            "Delivery token pool low (\(count)), replenishing...")
        do {
            try await fetchAndStoreTokens()
        } catch {
            SanchrLogger.crypto.error(
                "Delivery token replenish failed: \(error.localizedDescription)")
        }
    }

    // MARK: - InnerPayload Encode / Decode

    public func encodeInnerPayload(
        conversationId: String,
        messageId: String?,
        contentType: String,
        content: Data,
        isSync: Bool,
        expiresAfterSecs: Int64?
    ) throws -> Data {
        let payload = InnerPayload(
            conversationId: conversationId,
            messageId: messageId,
            contentType: contentType,
            content: content,
            isSync: isSync,
            expiresAfterSecs: expiresAfterSecs
        )
        do {
            return try JSONEncoder().encode(payload)
        } catch {
            throw SealedSenderError.innerPayloadEncodeFailed(underlying: error)
        }
    }

    public func decodeInnerPayload(_ data: Data) throws -> InnerPayload {
        do {
            return try JSONDecoder().decode(InnerPayload.self, from: data)
        } catch {
            throw SealedSenderError.innerPayloadDecodeFailed(underlying: error)
        }
    }

    public static func isInnerPayload(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["v"] != nil
    }

    // MARK: - Synchronous Lock Helpers (never cross an await boundary)

    /// Returns the cached certificate if it's still valid with refresh margin.
    private func getCachedCertificateIfValid() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let cert = cachedCertificate,
              Date().addingTimeInterval(Self.certRefreshMarginSeconds) < cachedCertificateExpiry
        else { return nil }
        return cert
    }

    /// Stores a freshly fetched certificate and its expiry.
    private func storeCertificate(_ data: Data, expiry: Date) {
        lock.lock()
        defer { lock.unlock() }
        cachedCertificate = data
        cachedCertificateExpiry = expiry
    }

    /// Loads the delivery token pool from Keychain on first access.
    private func loadPoolFromKeychainIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        guard !tokenPoolLoaded else { return }
        tokenPoolLoaded = true

        guard let data = try? keychain.read(forKey: KeychainKeys.deliveryTokenPool) else {
            return
        }
        guard let base64Strings = try? JSONDecoder().decode([String].self, from: data) else {
            SanchrLogger.crypto.warning("Failed to decode delivery token pool from Keychain")
            return
        }

        tokenPool = base64Strings.compactMap { Data(base64Encoded: $0) }
        SanchrLogger.crypto.info("Loaded \(self.tokenPool.count) delivery tokens from Keychain")
    }

    /// Pops the first token from the pool. Returns nil if pool is empty.
    private func popToken() -> (token: Data, remaining: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard !tokenPool.isEmpty else { return nil }
        let token = tokenPool.removeFirst()
        return (token, tokenPool.count)
    }

    /// Returns the current pool count.
    private func poolCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return tokenPool.count
    }

    /// Appends tokens to the pool. Returns the new total count.
    @discardableResult
    private func appendToPool(_ tokens: [Data]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        tokenPool.append(contentsOf: tokens)
        return tokenPool.count
    }

    /// Persists the current token pool to Keychain as a JSON array of base64 strings.
    private func persistPoolToKeychain() {
        let base64Strings: [String]
        lock.lock()
        base64Strings = tokenPool.map { $0.base64EncodedString() }
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(base64Strings)
            try keychain.save(data, forKey: KeychainKeys.deliveryTokenPool)
        } catch {
            SanchrLogger.crypto.error(
                "Failed to persist delivery token pool: \(error.localizedDescription)")
        }
    }

    /// Fetches a batch of delivery tokens from the server and appends to the pool.
    ///
    /// Concurrent calls are collapsed: if a fetch is already in-flight the second
    /// caller waits (via a short back-off poll) and returns without making a second
    /// RPC.  A single retry is attempted on transient failure before propagating.
    private func fetchAndStoreTokens() async throws {
        // Deduplication: if another fetch is in-flight, wait for it to finish
        // rather than issuing a redundant RPC.
        if !beginFetch() {
            SanchrLogger.crypto.debug("Token fetch already in-flight, waiting...")
            // Poll until the in-flight fetch finishes (max ~3 s).
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
                if !isFetchingTokensFlag() { return }
            }
            // Timed out waiting; attempt our own fetch below.
        }
        defer { endFetch() }

        var request = Sanchr_Messaging_DeliveryTokenRequest()
        request.count = Self.tokenBatchSize

        // Attempt with one retry on failure.
        var lastError: Error?
        for attempt in 1...2 {
            do {
                let response = try await messagingService.getDeliveryTokens(request)
                let newTokens = response.tokens
                guard !newTokens.isEmpty else {
                    SanchrLogger.crypto.warning("Server returned zero delivery tokens")
                    return
                }
                let total = appendToPool(newTokens)
                persistPoolToKeychain()
                SanchrLogger.crypto.info(
                    "Fetched \(newTokens.count) delivery tokens (attempt \(attempt)), pool now has \(total)")
                return
            } catch {
                // Log the actual GRPCStatus if available for diagnostics.
                if let grpcStatus = error as? GRPCStatus {
                    SanchrLogger.crypto.error(
                        "GetDeliveryTokens RPC failed (attempt \(attempt)): code=\(grpcStatus.code) message=\(grpcStatus.message ?? "<none>")")
                } else {
                    SanchrLogger.crypto.error(
                        "GetDeliveryTokens RPC failed (attempt \(attempt)): \(error)")
                }
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 s back-off
                }
            }
        }

        throw SealedSenderError.deliveryTokenFetchFailed(underlying: lastError!)
    }

    // MARK: - Inflight fetch flag helpers (called under lock)

    /// Atomically sets `isFetchingTokens` to `true` if it was `false`.
    /// Returns `true` if this caller "won" the right to perform the fetch.
    private func beginFetch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFetchingTokens else { return false }
        isFetchingTokens = true
        return true
    }

    private func endFetch() {
        lock.lock()
        defer { lock.unlock() }
        isFetchingTokens = false
    }

    private func isFetchingTokensFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFetchingTokens
    }
}

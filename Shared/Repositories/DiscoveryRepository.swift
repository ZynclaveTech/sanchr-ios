import CryptoKit
import Foundation
import SanchrShared

/// Repository for OPRF-PSI contact discovery.
///
/// Two-layer approach:
/// 1. Bloom filter fast path (cached hash, reduced privacy, quick negative filter)
/// 2. Full OPRF-PSI (cryptographic privacy, used for cold sync)
protocol DiscoveryRepositoryProtocol: AnyObject, Sendable {
    /// Full OPRF-PSI discovery flow.
    func discoverContacts(phoneNumbers: [String]) async throws -> [String]

    /// Bloom filter check (fast path).
    func bloomFilterCheck(phoneNumbers: [String]) async throws -> [Bool]
}

final class DiscoveryRepository: DiscoveryRepositoryProtocol, @unchecked Sendable {

    private let grpcClient: GRPCClientProtocol
    private let oprfClient: OPRFClientProtocol

    init(grpcClient: GRPCClientProtocol, oprfClient: OPRFClientProtocol) {
        self.grpcClient = grpcClient
        self.oprfClient = oprfClient
    }

    /// Server-side cap on blinded points per `OprfDiscover` call. Requests above
    /// this are rejected outright, so anyone with a normal-sized address book has
    /// to be evaluated in several rounds.
    private static let maxBatchSize = 500

    func discoverContacts(phoneNumbers: [String]) async throws -> [String] {
        guard !phoneNumbers.isEmpty else { return [] }

        // Blind one number at a time and keep the original index alongside each
        // point. `blind` skips numbers it cannot parse, so a batch call returns a
        // shorter array than it was given and the positions no longer line up with
        // the input — mapping a match back by position would then name the wrong
        // contact. Pairing each point with its source index removes that class of
        // bug entirely.
        var indexedPoints: [(index: Int, factor: Data, point: Data)] = []
        for (index, phone) in phoneNumbers.enumerated() {
            let (factors, points) = oprfClient.blind(phoneNumbers: [phone])
            guard let factor = factors.first, let point = points.first else {
                SanchrLogger.sync.debug("Skipping unblindable number at index \(index)")
                continue
            }
            indexedPoints.append((index, factor, point))
        }

        guard !indexedPoints.isEmpty else { return [] }

        // Evaluate in server-sized batches, unblinding each batch as it returns.
        var unblindedByIndex: [(index: Int, unblinded: Data)] = []
        for batch in indexedPoints.chunked(into: Self.maxBatchSize) {
            var request = Sanchr_Discovery_OprfDiscoverRequest()
            request.blindedPoints = batch.map(\.point)

            let response = try await grpcClient.discoveryService.oprfDiscover(request)

            guard response.evaluatedPoints.count == batch.count else {
                throw AppError.unknown(
                    underlying:
                        "OPRF returned \(response.evaluatedPoints.count) points for \(batch.count) queries"
                )
            }

            let unblinded = oprfClient.unblind(
                serverResponses: response.evaluatedPoints,
                blindingFactors: batch.map(\.factor)
            )
            for (offset, value) in unblinded.enumerated() {
                unblindedByIndex.append((batch[offset].index, value))
            }
        }

        // Fetch the registered set once — it is the same for every batch.
        let setRequest = Sanchr_Discovery_GetRegisteredSetRequest()
        let setResponse = try await grpcClient.discoveryService.getRegisteredSet(setRequest)
        let registeredSet = Set(setResponse.setElements)

        let matchOffsets = oprfClient.findMatches(
            unblindedResults: unblindedByIndex.map(\.unblinded),
            registeredSet: registeredSet
        )

        // Map back through the recorded original indices, never by position.
        return matchOffsets.compactMap { offset -> String? in
            guard offset < unblindedByIndex.count else { return nil }
            let originalIndex = unblindedByIndex[offset].index
            guard originalIndex < phoneNumbers.count else { return nil }
            return phoneNumbers[originalIndex]
        }
    }

    func bloomFilterCheck(phoneNumbers: [String]) async throws -> [Bool] {
        let request = Sanchr_Discovery_GetBloomFilterRequest()
        let response = try await grpcClient.discoveryService.getBloomFilter(request)

        // Reconstruct Bloom filter from server response
        let salt = response.dailySalt

        return phoneNumbers.map { phone in
            // SHA-256(phone || salt) and check against filter bits
            var hasher = SHA256()
            hasher.update(data: Data(phone.utf8))
            hasher.update(data: salt)
            let hash = Data(hasher.finalize())

            // Check Bloom filter bits
            return checkBloomFilter(
                hash: hash,
                filterBits: response.filterBits,
                numBits: response.numBits,
                numHashes: response.numHashes
            )
        }
    }

    private func checkBloomFilter(
        hash: Data,
        filterBits: Data,
        numBits: UInt64,
        numHashes: UInt32
    ) -> Bool {
        guard numBits > 0, !filterBits.isEmpty else { return false }

        for i in 0..<numHashes {
            let h1 = hash.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
            let h2 = hash.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
            let combined = h1 &+ h2 &* UInt64(i)
            let bitIndex = Int(combined % numBits)
            let byteIndex = bitIndex / 8
            let bitOffset = bitIndex % 8

            guard byteIndex < filterBits.count else { return false }
            if filterBits[byteIndex] & (1 << bitOffset) == 0 {
                return false
            }
        }
        return true
    }
}

extension Array {
    /// Splits into consecutive slices of at most `size` elements.
    /// Used to keep OPRF requests under the server's per-call cap.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

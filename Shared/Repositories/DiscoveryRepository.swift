import CryptoKit
import Foundation

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

    func discoverContacts(phoneNumbers: [String]) async throws -> [String] {
        // Step 1: Blind phone numbers
        let (blindingFactors, blindedPoints) = oprfClient.blind(phoneNumbers: phoneNumbers)

        // Step 2: Send blinded points to server for OPRF evaluation
        var request = Vync_Discovery_OprfDiscoverRequest()
        request.blindedPoints = blindedPoints

        let response = try await grpcClient.discoveryService.oprfDiscover(request)

        // Step 3: Unblind server responses
        let unblindedResults = oprfClient.unblind(
            serverResponses: response.evaluatedPoints,
            blindingFactors: blindingFactors
        )

        // Step 4: Get registered user set from server
        let setRequest = Vync_Discovery_GetRegisteredSetRequest()
        let setResponse = try await grpcClient.discoveryService.getRegisteredSet(setRequest)
        let registeredSet = Set(setResponse.setElements)

        // Step 5: Find matches
        let matchIndices = oprfClient.findMatches(
            unblindedResults: unblindedResults,
            registeredSet: registeredSet
        )

        return matchIndices.map { phoneNumbers[$0] }
    }

    func bloomFilterCheck(phoneNumbers: [String]) async throws -> [Bool] {
        let request = Vync_Discovery_GetBloomFilterRequest()
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

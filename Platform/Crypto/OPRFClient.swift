import Foundation
import SanchrShared

protocol OPRFClientProtocol: Sendable {
    func blind(phoneNumbers: [String]) -> (blindingFactors: [Data], blindedPoints: [Data])
    func unblind(serverResponses: [Data], blindingFactors: [Data]) -> [Data]
    func findMatches(unblindedResults: [Data], registeredSet: Set<Data>) -> [Int]
}

final class OPRFClient: OPRFClientProtocol, @unchecked Sendable {

    func blind(phoneNumbers: [String]) -> (blindingFactors: [Data], blindedPoints: [Data]) {
        var factors: [Data] = []
        var points: [Data] = []

        for phone in phoneNumbers {
            var blindingScalar = Data(count: 32)
            var blindedPoint = Data(count: 32)

            let result = blindingScalar.withUnsafeMutableBytes { scalarPtr in
                blindedPoint.withUnsafeMutableBytes { pointPtr in
                    phone.withCString { phonePtr in
                        vync_oprf_blind(
                            phonePtr,
                            scalarPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            pointPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        )
                    }
                }
            }

            guard result == 0 else {
                // Skip invalid phone numbers
                continue
            }

            factors.append(blindingScalar)
            points.append(blindedPoint)
        }

        return (factors, points)
    }

    func unblind(serverResponses: [Data], blindingFactors: [Data]) -> [Data] {
        precondition(serverResponses.count == blindingFactors.count)
        var results: [Data] = []

        for (response, factor) in zip(serverResponses, blindingFactors) {
            var unblindedPoint = Data(count: 32)

            let result = response.withUnsafeBytes { respPtr in
                factor.withUnsafeBytes { factorPtr in
                    unblindedPoint.withUnsafeMutableBytes { outPtr in
                        vync_oprf_unblind(
                            respPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            factorPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            outPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        )
                    }
                }
            }

            if result == 0 {
                results.append(unblindedPoint)
            }
        }

        return results
    }

    func findMatches(unblindedResults: [Data], registeredSet: Set<Data>) -> [Int] {
        var matchIndices: [Int] = []
        for (index, result) in unblindedResults.enumerated() {
            if registeredSet.contains(result) {
                matchIndices.append(index)
            }
        }
        return matchIndices
    }
}

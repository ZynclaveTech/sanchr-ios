import CryptoKit
import NIOSSL
import XCTest

@testable import SanchrShared

/// TLS pinning must actually reject an unpinned chain.
///
/// A complete pinning validator existed with zero callers and null production
/// pins, so every shipping build trusted any certificate a system-trusted CA
/// would sign. That matters more than usual here: the pinned channel is the one
/// that distributes pre-key bundles, so a substituted certificate is a route to
/// substituted identity keys.
final class CertificatePinningTests: XCTestCase {

    /// Self-signed, CN=pinning-test.invalid. Only its public key is read — no
    /// validity or chain checking happens in the code under test — so this does
    /// not become a time bomb when it expires.
    private static let testCertPEM = """
        -----BEGIN CERTIFICATE-----
        MIIDITCCAgmgAwIBAgIUaxwquXWvWB3Fh4XAurCpKZT2VyEwDQYJKoZIhvcNAQEL
        BQAwHzEdMBsGA1UEAwwUcGlubmluZy10ZXN0LmludmFsaWQwIBcNMjYwODI2MDI1
        NzEwWhgPMjEyNjA4MDIwMjU3MTBaMB8xHTAbBgNVBAMMFHBpbm5pbmctdGVzdC5p
        bnZhbGlkMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzYF++eaCRX/l
        PJQTpNXq4oqJk0T+5GjP378YB5lMZdP3MQjJnAXTWy8mHYYEV21cZZcBdSo8dn+4
        sQ/Sox9DmBVA3Z6eR+nejXrhmdeScbEKodJ5bcZPS+QgQPdzp5ZqVOwQa/1mHKLi
        4SB7mkwdGcUlJYb7mJmfqQK3oDv/83mUaZu6OE6tnERactDFviTnfPcdM6cnwR+C
        wuvU1v878e83uJlgsD6vR5nmB4Fjjve/5/zjYdiXgMLTvu67i7Qwksrt9fbxRkYh
        h6r6VksTdumboroLyGHiCpJ5cmM3sMEhGYbibdzYNNEb2hM7TOB+D9QUUnWq/nvd
        Tn0kd5laKQIDAQABo1MwUTAdBgNVHQ4EFgQUcn+yg7cUXoAtpvbrRv9ekbxmaCkw
        HwYDVR0jBBgwFoAUcn+yg7cUXoAtpvbrRv9ekbxmaCkwDwYDVR0TAQH/BAUwAwEB
        /zANBgkqhkiG9w0BAQsFAAOCAQEActvUSe1oXyBwaEbfAV2AHioQwe9EYKx+hdLJ
        ogtQQ4ZnnnRTjUVvpHj4JrekGoeNzbeTNuicOtSgDbf5h1nxEe/dakncb++2J4F9
        FciHGPaMovoe8Gaqv39n4mwXp3RCeL/JJz9OaZgkkr07Y2qRjHoDxjRat3Dpvz9z
        CYHByxLPlmGogMg7iPBCUFX4wT9qTflcZyTuVh71EZ5v6VA24FziOq0lwNNcL5c6
        J5ocUi1mwvuTF4ga/Cq+2eGni58zZvtdDqOS6ENoKYucoYLExctgTgV6xZs397dM
        yOmRYigfM+xnnvXPJ4RagROROcxTpX6lDEy9lnt92d2UlVXLGQ==
        -----END CERTIFICATE-----
        """

    private func makeCertificate() throws -> NIOSSLCertificate {
        try NIOSSLCertificate(bytes: Array(Self.testCertPEM.utf8), format: .pem)
    }

    func test_pinIsStableForTheSameCertificate() throws {
        let cert = try makeCertificate()
        XCTAssertEqual(
            try CertificatePinning.spkiPin(for: cert),
            try CertificatePinning.spkiPin(for: cert)
        )
    }

    /// The pin must cover the public key, not the whole certificate. The previous
    /// implementation hashed the leaf DER, which changes on every renewal — with
    /// Let's Encrypt renewing roughly every 60 days, that would have taken every
    /// installed client offline.
    func test_pinIsDerivedFromPublicKeyNotWholeCertificate() throws {
        let cert = try makeCertificate()
        let spkiPin = try CertificatePinning.spkiPin(for: cert)
        let derPin = Data(SHA256.hash(data: Data(try cert.toDERBytes())))
            .base64EncodedString()

        XCTAssertNotEqual(
            spkiPin, derPin,
            "an SPKI pin must not equal a hash of the whole certificate")
    }

    func test_matchingPinIsAccepted() throws {
        let cert = try makeCertificate()
        let pin = try CertificatePinning.spkiPin(for: cert)
        XCTAssertNoThrow(try CertificatePinning.validate(chain: [cert], against: [pin]))
    }

    func test_nonMatchingPinIsRejected() throws {
        let cert = try makeCertificate()
        XCTAssertThrowsError(
            try CertificatePinning.validate(
                chain: [cert], against: ["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="])
        ) { error in
            guard case CertificatePinning.PinningError.noPinMatched = error else {
                return XCTFail("expected noPinMatched, got \(error)")
            }
        }
    }

    /// A backup pin further up the chain is the whole reason rotation does not
    /// take clients offline, so a match on a non-leaf entry must be accepted.
    func test_matchAnywhereInChainIsAccepted() throws {
        let cert = try makeCertificate()
        let pin = try CertificatePinning.spkiPin(for: cert)
        XCTAssertNoThrow(
            try CertificatePinning.validate(chain: [cert], against: ["unrelated", pin]))
    }

    func test_emptyChainIsRejected() {
        XCTAssertThrowsError(
            try CertificatePinning.validate(chain: [], against: ["anything"])
        ) { error in
            guard case CertificatePinning.PinningError.emptyChain = error else {
                return XCTFail("expected emptyChain, got \(error)")
            }
        }
    }

    /// With no pins nothing can match, so validation fails rather than passing
    /// vacuously. Whether to pin at all is decided where the channel is built.
    func test_emptyPinSetRejectsRatherThanPassingVacuously() throws {
        let cert = try makeCertificate()
        XCTAssertThrowsError(try CertificatePinning.validate(chain: [cert], against: []))
    }

    // MARK: - Shipping configuration

    /// Guards the defect this change fixes: a production build with no pins
    /// trusts any CA-signed certificate.
    func test_productionConfiguration_hasPinsForBothHosts() {
        XCTAssertFalse(AppConfiguration.production.grpcCertificatePins.isEmpty)
        XCTAssertFalse(AppConfiguration.production.callCertificatePins.isEmpty)
    }

    /// One pin means a server key rotation locks every client out until they
    /// update. At least two — leaf plus a CA — keeps them online through it.
    func test_productionPins_includeABackup() {
        XCTAssertGreaterThanOrEqual(
            AppConfiguration.production.grpcCertificatePins.count, 2,
            "ship a backup pin so key rotation cannot take clients offline")
        XCTAssertGreaterThanOrEqual(
            AppConfiguration.production.callCertificatePins.count, 2,
            "ship a backup pin so key rotation cannot take clients offline")
    }

    /// Pins are base64 SHA-256. A malformed pin can never match and would fail
    /// closed on every connection.
    func test_productionPins_areWellFormed() {
        let all = AppConfiguration.production.grpcCertificatePins
            .union(AppConfiguration.production.callCertificatePins)
        XCTAssertFalse(all.isEmpty)
        for pin in all {
            let decoded = Data(base64Encoded: pin)
            XCTAssertNotNil(decoded, "\(pin) is not valid base64")
            XCTAssertEqual(decoded?.count, 32, "\(pin) is not a 32-byte digest")
        }
    }

    /// api.sanchr.io and call.sanchr.io serve nothing; the deployed ingress is
    /// .com. A release build aimed at the .io hosts could not connect at all.
    func test_productionPointsAtTheDeployedHosts() {
        XCTAssertEqual(AppConfiguration.production.grpcHost, "api.sanchr.com")
        XCTAssertEqual(AppConfiguration.production.callHost, "call.sanchr.com")
    }
}

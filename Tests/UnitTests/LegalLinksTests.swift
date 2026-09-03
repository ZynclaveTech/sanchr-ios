import XCTest
@testable import Sanchr

/// App Review follows "Terms & Privacy" and the login screen's agreement
/// line. Both used to dead-end: the row opened the privacy toggles and the
/// line was plain text.
final class LegalLinksTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testDocumentsLiveOnTheCanonicalDomainOverHTTPS() {
        XCTAssertEqual(LegalDocument.privacy.url.absoluteString, "https://sanchr.com/privacy")
        XCTAssertEqual(LegalDocument.terms.url.absoluteString, "https://sanchr.com/terms")
        for document in LegalDocument.allCases {
            XCTAssertEqual(LegalDocument(url: document.url), document, "a tapped link maps back to its document")
        }
        XCTAssertNil(LegalDocument(url: URL(string: "https://example.com/privacy")!))
    }

    func testSettingsRowLeadsToTheDocumentsNotThePrivacyToggles() throws {
        let settings = try source("Features/Settings/Presentation/SettingsView.swift")
        let row = try XCTUnwrap(settings.range(of: "title: \"Terms & Privacy\","))
        let after = String(settings[row.upperBound...].prefix(200))
        XCTAssertTrue(after.contains("destination: AnyView(LegalView())"))
        XCTAssertFalse(after.contains("PrivacyView()"))
    }

    func testLoginAgreementLineIsMadeOfRealLinks() throws {
        let login = try source("Features/Auth/Presentation/LoginView.swift")
        XCTAssertTrue(login.contains("[Privacy Policy](\\(LegalDocument.privacy.url))"))
        XCTAssertTrue(login.contains("[Terms of Service](\\(LegalDocument.terms.url))"))
        XCTAssertTrue(login.contains("SafariSheet(url: document.url)"), "opens in-app, not by leaving to Safari")
        XCTAssertFalse(login.contains("Text(\"By continuing, you agree to our Privacy Policy and Terms of Service\")"))
    }
}

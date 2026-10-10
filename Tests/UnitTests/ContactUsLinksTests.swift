import XCTest

@testable import Sanchr

/// The Contact Us "quick links" have to be tappable.
///
/// All three were bare `HStack`s — no Button, no NavigationLink, no gesture —
/// inside the same card, with the same icon tile and type, as the rows
/// elsewhere in Settings that do navigate. Including the emergency address,
/// which is the one a user in trouble would reach for.
final class ContactUsLinksTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Features/Settings/Presentation/ContactUsView.swift"),
            encoding: .utf8)
    }

    func test_everyQuickLinkRowIsInsideAControl() throws {
        let view = try source()
        let start = try XCTUnwrap(view.range(of: "private var quickLinks: some View {"))
        let end = try XCTUnwrap(view.range(of: "private func openMail(", range: start.upperBound..<view.endIndex))
        let block = String(view[start.upperBound..<end.lowerBound])

        let rows = block.components(separatedBy: "ContactLinkRow(").count - 1
        let controls = (block.components(separatedBy: "Button {").count - 1)
            + (block.components(separatedBy: "NavigationLink {").count - 1)

        XCTAssertEqual(rows, 3, "expected the three quick-link rows")
        XCTAssertEqual(controls, rows, "every row must be wrapped in a control")
    }

    func test_bothAddressesOpenMail() throws {
        let view = try source()

        XCTAssertTrue(view.contains(#"openMail(to: "support@sanchr.com""#))
        XCTAssertTrue(view.contains(#"openMail(to: "emergency@sanchr.com""#))
    }

    func test_thereIsAFallbackWhenNoMailAppExists() throws {
        let view = try source()
        let start = try XCTUnwrap(view.range(of: "private func openMail("))
        let body = String(view[start.upperBound...].prefix(700))

        // A row that silently does nothing is what this screen already had.
        XCTAssertTrue(body.contains("UIPasteboard.general.string = address"))
        XCTAssertTrue(body.contains("canOpenURL"))
    }
}

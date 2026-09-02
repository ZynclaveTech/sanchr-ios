import UIKit
import XCTest

@testable import Sanchr

/// The design system is built on Afacad, and `SanchrTypography.font` falls
/// back to a fixed-size system font when the family is not registered — so
/// with the fonts bundled but never registered, every screen rendered in
/// SF Rounded at sizes that ignored Dynamic Type.
final class FontRegistrationTests: XCTestCase {

    func testTheBundledFontsAreDeclaredForRegistration() throws {
        let declared = try XCTUnwrap(Bundle.main.infoDictionary?["UIAppFonts"] as? [String])
        XCTAssertEqual(Set(declared), ["Afacad-Variable.ttf", "Inter-Variable.ttf"])
        for file in declared {
            let name = (file as NSString).deletingPathExtension
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "ttf"), "\(file) is declared but not in the bundle")
        }
    }

    func testAfacadAndInterAreRegistered() {
        XCTAssertTrue(UIFont.familyNames.contains("Afacad"), "families: \(UIFont.familyNames.sorted())")
        XCTAssertTrue(UIFont.familyNames.contains("Inter"))
    }

    /// The exact lookup `SanchrTypography.font` gates on, and the face
    /// `Font.custom("Afacad")` resolves to.
    func testTheTypographyGateResolvesAfacad() {
        XCTAssertFalse(UIFont.fontNames(forFamilyName: "Afacad").isEmpty)
        XCTAssertNotNil(UIFont(name: "Afacad-Regular", size: 16))
    }
}

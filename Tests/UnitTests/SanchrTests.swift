import XCTest
@testable import Sanchr

final class SanchrTests: XCTestCase {
    func testDesignTokensExist() {
        // Verify design system tokens compile
        XCTAssertNotNil(SanchrColors.primary)
    }
}

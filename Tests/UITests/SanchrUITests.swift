import XCTest
import SanchrShared

final class SanchrUITests: XCTestCase {
    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
    }
}

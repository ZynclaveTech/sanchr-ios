import XCTest
import CoreImage
@testable import Sanchr

final class VideoFilterTests: XCTestCase {

    func test_allCases_haveNonEmptyDisplayName() {
        for filter in VideoFilter.allCases {
            XCTAssertFalse(filter.displayName.isEmpty,
                "\(filter) has empty displayName")
        }
    }

    func test_none_producesNilCIFilter() {
        XCTAssertNil(VideoFilter.none.makeCIFilter())
    }

    func test_smoothSkin_producesGaussianBlur() {
        let f = VideoFilter.smoothSkin.makeCIFilter()
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.name, "CIGaussianBlur")
    }

    func test_warm_producesTemperatureAndTint() {
        let f = VideoFilter.warm.makeCIFilter()
        XCTAssertEqual(f?.name, "CITemperatureAndTint")
    }

    func test_cool_producesTemperatureAndTint() {
        let f = VideoFilter.cool.makeCIFilter()
        XCTAssertEqual(f?.name, "CITemperatureAndTint")
    }

    func test_blackAndWhite_producesColorMonochrome() {
        let f = VideoFilter.blackAndWhite.makeCIFilter()
        XCTAssertEqual(f?.name, "CIColorMonochrome")
    }

    func test_vivid_producesVibrance() {
        let f = VideoFilter.vivid.makeCIFilter()
        XCTAssertEqual(f?.name, "CIVibrance")
    }
}

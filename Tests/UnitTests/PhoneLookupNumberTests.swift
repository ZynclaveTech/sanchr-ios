import XCTest

@testable import Sanchr

/// Find-by-number had ten countries of its own and sent the server whatever
/// was typed after the calling code.
final class PhoneLookupNumberTests: XCTestCase {

    private func country(_ region: String) throws -> PhoneCountry {
        try XCTUnwrap(PhoneCountry.withRegion(region), "\(region) is missing from the country table")
    }

    func testWhatPeopleTypeBecomesTheNumberTheServerKnows() throws {
        XCTAssertEqual(try country("US").e164(fromInput: "(415) 555-1234"), "+14155551234")
        XCTAssertEqual(try country("IN").e164(fromInput: "98765 43210"), "+919876543210")
    }

    /// The 0 dialled inside the country is not part of the number.
    func testTheTrunkZeroIsDropped() throws {
        XCTAssertEqual(try country("GB").e164(fromInput: "07700 900123"), "+447700900123")
        XCTAssertEqual(try country("IN").e164(fromInput: "09876543210"), "+919876543210")
    }

    func testSomethingThatIsNotANumberForThatCountryIsNotLookedUp() throws {
        XCTAssertNil(try country("US").e164(fromInput: ""))
        XCTAssertNil(try country("US").e164(fromInput: "555"))
        XCTAssertNil(try country("IN").e164(fromInput: "abc"))
    }

    /// Countries the old list of ten left out could not be searched at all.
    func testCountriesOutsideTheOldListOfTenCanBeLookedUp() throws {
        for region in ["NP", "LK", "TH", "AE", "SG", "ZA", "KE"] {
            XCTAssertNotNil(PhoneCountry.withRegion(region), "\(region)")
        }
        XCTAssertGreaterThan(PhoneCountry.all.count, 150)
    }

    /// The old list called it "UK", which no device reports, so a British
    /// phone started on +1.
    func testTheUnitedKingdomIsUnderTheRegionDevicesReport() throws {
        XCTAssertEqual(try country("GB").callingCode, "+44")
        XCTAssertNil(PhoneCountry.withRegion("UK"))
    }

    /// The screen has to use the shared list and picker, not carry its own.
    func testTheLookupScreenUsesTheSharedCountryList() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Features/Contacts/Presentation/PhoneNumberLookupView.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("CountryPickerView(selection: $country)"))
        XCTAssertTrue(source.contains("country.e164(fromInput: phoneNumber)"))
        XCTAssertFalse(source.contains("countryCodes"), "no private list of countries")
    }
}

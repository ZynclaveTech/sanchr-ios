import XCTest

@testable import Sanchr

/// Turning an address-book number into the E.164 the server registered.
///
/// People save numbers however they like — "9569740653", "095697 40653",
/// "0091-9569740653". Discovery is blind, so a number that expands wrongly
/// simply never matches its own account: the contact shows as not on Sanchr,
/// forever, with nothing to say why.
final class E164ExpansionTests: XCTestCase {

    private let indiaOwnNumber = "+919569740653"   // +91 and a 10-digit national

    private func expand(_ raw: String) -> String? {
        ContactDataSource.e164PhoneNumber(
            raw,
            defaultCallingCode: ContactDataSource.callingCode(fromE164: indiaOwnNumber),
            nationalNumberLength: ContactDataSource.nationalNumberLength(ofE164: indiaOwnNumber)
        )
    }

    /// The bug. India's calling code is 91 and 91 is also a valid mobile
    /// prefix there, so a ten-digit number beginning "91" satisfied the
    /// country-code test and came out as "+9198765432" — ten digits where
    /// twelve were needed.
    func testATenDigitNumberBeginningWithItsOwnCallingCodeIsNational() {
        XCTAssertEqual(expand("9198765432"), "+919198765432")
        XCTAssertEqual(expand("9187654321"), "+919187654321")
    }

    func testAnOrdinaryNationalNumberIsExpanded() {
        XCTAssertEqual(expand("9569740653"), "+919569740653")
        XCTAssertEqual(expand("9876543210"), "+919876543210")
    }

    /// Still has to recognise a number that genuinely carries its country code.
    func testACountryCodeWithoutAPlusIsRecognised() {
        XCTAssertEqual(expand("919569740653"), "+919569740653")
    }

    func testAlreadyInternationalIsLeftAlone() {
        XCTAssertEqual(expand("+919569740653"), "+919569740653")
        XCTAssertEqual(expand("+1 415 555 0123"), "+14155550123")
    }

    /// A leading trunk zero is national dialling only and goes when the number
    /// goes international.
    func testTrunkZeroIsDropped() {
        XCTAssertEqual(expand("095697 40653"), "+919569740653")
    }

    /// "00" is the other international prefix in common use.
    func testDoubleZeroPrefixIsTreatedAsPlus() {
        XCTAssertEqual(expand("0091-9569740653"), "+919569740653")
    }

    func testFormattingIsIgnored() {
        XCTAssertEqual(expand("(95697) 40653"), "+919569740653")
        XCTAssertEqual(expand("95697-40653"), "+919569740653")
    }

    // MARK: - Deriving the national length

    func testNationalLengthComesFromTheUsersOwnNumber() {
        XCTAssertEqual(ContactDataSource.nationalNumberLength(ofE164: "+919569740653"), 10)
        XCTAssertEqual(ContactDataSource.nationalNumberLength(ofE164: "+14155550123"), 10)
        XCTAssertEqual(ContactDataSource.nationalNumberLength(ofE164: "+447911123456"), 10)
    }

    func testNationalLengthIsNilWhenItCannotBeDerived() {
        XCTAssertNil(ContactDataSource.nationalNumberLength(ofE164: ""))
        XCTAssertNil(ContactDataSource.nationalNumberLength(ofE164: "+91"))
    }

    /// Signing in is what supplies the length, so expansion has to stay
    /// reasonable before that — it must not start returning nil or crashing.
    func testWithoutALengthTheOlderBehaviourStillApplies() {
        let out = ContactDataSource.e164PhoneNumber("9876543210", defaultCallingCode: "+91")
        XCTAssertEqual(out, "+919876543210")
    }

    func testEmptyAndJunkExpandToNothing() {
        XCTAssertNil(expand(""))
        XCTAssertNil(expand("   "))
        XCTAssertNil(expand("abc"))
    }
}

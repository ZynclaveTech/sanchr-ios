import XCTest
import Contacts
import SanchrShared
@testable import Sanchr

final class StrippedContactTests: XCTestCase {

    private func makeFullContact() -> CNContact {
        let c = CNMutableContact()
        c.givenName = "Siddharth"
        c.familyName = "Sharma"
        c.organizationName = "Evil Corp"
        c.jobTitle = "CTO"
        c.note = "met at conference"
        c.imageData = Data([0xFF, 0xD8, 0xFF])
        c.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile,
                           value: CNPhoneNumber(stringValue: "+91 63946 37912"))
        ]
        c.emailAddresses = [
            CNLabeledValue(label: CNLabelHome, value: "sid@example.com" as NSString)
        ]
        let postal = CNMutablePostalAddress()
        postal.street = "221B Baker St"
        c.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: postal)]
        c.urlAddresses = [CNLabeledValue(label: "website", value: "https://evil.corp" as NSString)]
        return c
    }

    func test_strip_keepsNameAndPhoneAndEmail() {
        let stripped = ContactSource.strip(makeFullContact())
        XCTAssertNotNil(stripped)
        XCTAssertEqual(stripped?.displayName, "Siddharth Sharma")
        XCTAssertEqual(stripped?.phoneNumbers, ["+916394637912"])
        XCTAssertEqual(stripped?.emails, ["sid@example.com"])
    }

    func test_strip_discardsAllSensitiveFields() throws {
        let stripped = try XCTUnwrap(ContactSource.strip(makeFullContact()))
        let data = try JSONEncoder().encode(stripped)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("Evil Corp"))
        XCTAssertFalse(json.contains("CTO"))
        XCTAssertFalse(json.contains("conference"))
        XCTAssertFalse(json.contains("Baker"))
        XCTAssertFalse(json.contains("evil.corp"))
        XCTAssertFalse(json.contains("imageData"))
    }

    func test_strip_lockedKeySet_inJSON() throws {
        let stripped = try XCTUnwrap(ContactSource.strip(makeFullContact()))
        let data = try JSONEncoder().encode(stripped)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(dict.keys), Set(["displayName", "phoneNumbers", "emails"]))
    }

    func test_strip_returnsNil_whenNoPhoneOrEmail() {
        let c = CNMutableContact()
        c.givenName = "Empty"
        XCTAssertNil(ContactSource.strip(c))
    }

    func test_strip_e164Normalization() {
        // Use explicit "+1" prefix so normalization is deterministic regardless
        // of simulator region (otherwise default-region country code kicks in).
        let c = CNMutableContact()
        c.givenName = "Test"
        c.phoneNumbers = [
            CNLabeledValue(label: nil, value: CNPhoneNumber(stringValue: "+1 (415) 555-0100"))
        ]
        let stripped = ContactSource.strip(c)
        XCTAssertEqual(stripped?.phoneNumbers.first, "+14155550100")
    }

    func test_normalizeE164_stripsFormattingCharacters() {
        XCTAssertEqual(ContactSource.normalizeE164("+44 20 7946 0000"), "+442079460000")
        XCTAssertEqual(ContactSource.normalizeE164("+1-415-555-0100"), "+14155550100")
        XCTAssertNil(ContactSource.normalizeE164(""))
        XCTAssertNil(ContactSource.normalizeE164("abc"))
    }
}

import XCTest
import SanchrShared

/// A link preview is a request this device makes because a message said so.
/// It may go to a site on the internet, and nowhere else.
final class LinkPreviewHostPolicyTests: XCTestCase {

    private func fetchable(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return LinkPreviewHostPolicy.isFetchable(url)
    }

    func testOrdinaryPublicLinksAreFetched() {
        XCTAssertTrue(fetchable("https://example.com/a?b=1"))
        XCTAssertTrue(fetchable("http://sub.example.co.uk/a"))
        XCTAssertTrue(fetchable("http://93.184.216.34/x"))
        XCTAssertTrue(fetchable("https://[2606:4700:4700::1111]/"))
    }

    func testOnlyWebSchemesAreFetched() {
        XCTAssertFalse(fetchable("file:///etc/hosts"))
        XCTAssertFalse(fetchable("ftp://example.com/a"))
        XCTAssertFalse(fetchable("mailto:someone@example.com"))
    }

    func testTheDeviceAndItsNetworkAreNotFetched() {
        for link in [
            "http://127.0.0.1:8080/x", "http://10.0.0.5/x", "http://172.16.0.1/x", "http://192.168.0.1/x",
            "http://169.254.169.254/latest/meta-data", "http://0.0.0.0/x", "http://100.64.0.1/x",
            "http://224.0.0.1/x", "http://localhost/x", "http://router/x",
            "http://printer.local/x", "http://db.internal/x", "http://nas.home.arpa/x",
        ] {
            XCTAssertFalse(fetchable(link), link)
        }
    }

    /// The neighbours of the private ranges are ordinary addresses.
    func testRangeBoundariesStayPublic() {
        XCTAssertTrue(fetchable("http://100.63.255.255/x"))
        XCTAssertTrue(fetchable("http://100.128.0.1/x"))
        XCTAssertTrue(fetchable("http://172.32.0.1/x"))
        XCTAssertTrue(fetchable("http://11.0.0.1/x"))
    }

    /// Userinfo is not the host, however much it is made to look like one.
    func testUserinfoCannotSmuggleAPrivateHost() {
        XCTAssertFalse(fetchable("https://example.com@127.0.0.1/admin"))
        XCTAssertFalse(fetchable("https://example.com@192.168.1.1/"))
        XCTAssertFalse(fetchable("https://example.com@[::1]/"))
        XCTAssertTrue(fetchable("https://user@example.com/"))
    }

    /// Each of these is loopback to some resolvers and a meaningless string to
    /// others; the fetch must not be how the app finds out which.
    func testNonStandardSpellingsOfAnAddressAreNotFetched() {
        for link in [
            "http://2130706433/x", "http://0x7f.1/x", "http://127.1/x",
            "http://0177.0.0.1/x", "http://0x7f000001/x", "http://127.0.0.1./x",
        ] {
            XCTAssertFalse(fetchable(link), link)
        }
    }

    func testANameWithHexLookingLabelsIsStillAName() {
        XCTAssertTrue(fetchable("https://face.cafe/x"))
        XCTAssertTrue(fetchable("https://9gag.com/x"))
    }

    func testOnlyGlobalUnicastIPv6IsFetched() {
        for link in [
            "http://[::1]/", "http://[::]/", "http://[fe80::1]/", "http://[fc00::1]/", "http://[fd12:3456::1]/",
            "http://[ff02::1]/", "http://[::ffff:127.0.0.1]/", "http://[64:ff9b::7f00:1]/",
            // 6to4 and Teredo sit inside 2000::/3 and both embed 127.0.0.1 here.
            "http://[2002:7f00:1::]/", "http://[2001:0:7f00:1::]/",
        ] {
            XCTAssertFalse(fetchable(link), link)
        }
    }
}

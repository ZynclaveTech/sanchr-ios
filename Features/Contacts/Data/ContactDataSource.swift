import CryptoKit
import Foundation
import SanchrShared

/// Data source for contact-related gRPC service calls.
/// Translates between domain models and Sanchr_Contacts protobuf messages.
final class ContactDataSource: @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private let localDatabase: LocalDatabaseProtocol

    private var contactClient: Sanchr_Contacts_ContactServiceAsyncClientProtocol {
        grpcClient.contactService
    }

    init(grpcClient: GRPCClientProtocol, localDatabase: LocalDatabaseProtocol) {
        self.grpcClient = grpcClient
        self.localDatabase = localDatabase
    }

    // MARK: - Sync Contacts

    /// Sends SHA-256 hashed phone numbers to the server and returns matched Sanchr users.
    func syncContacts(phoneHashes: [Data]) async throws -> [User] {
        var request = Sanchr_Contacts_SyncContactsRequest()
        request.phoneHashes = phoneHashes

        SanchrLogger.network.info(
            "ContactDataSource: syncContacts with \(phoneHashes.count) hashes")
        let response = try await contactClient.syncContacts(request)

        let users = response.matches.map(Self.mapMatchedContactToUser)

        // Cache locally
        for user in users {
            try? await localDatabase.saveContact(user)
        }

        return users
    }

    // MARK: - Get Contacts

    /// Fetches the full contact list from the server and updates local cache.
    func getContacts() async throws -> [User] {
        let request = Sanchr_Contacts_GetContactsRequest()

        SanchrLogger.network.info("ContactDataSource: getContacts")
        let response = try await contactClient.getContacts(request)

        let users = response.contacts.map(Self.mapContactToUser)

        // Refresh local cache
        for user in users {
            try? await localDatabase.saveContact(user)
        }

        return users
    }

    // MARK: - Block / Unblock

    /// Blocks a contact by user ID.
    func blockContact(userId: String) async throws {
        var request = Sanchr_Contacts_BlockContactRequest()
        request.contactUserID = userId

        SanchrLogger.network.info("ContactDataSource: blockContact \(userId.prefix(8))...")
        _ = try await contactClient.blockContact(request)
    }

    /// Unblocks a previously blocked contact.
    func unblockContact(userId: String) async throws {
        var request = Sanchr_Contacts_UnblockContactRequest()
        request.contactUserID = userId

        SanchrLogger.network.info("ContactDataSource: unblockContact \(userId.prefix(8))...")
        _ = try await contactClient.unblockContact(request)
    }

    // MARK: - Blocked List

    /// Fetches the list of blocked user IDs from the server.
    func getBlockedList() async throws -> [String] {
        let request = Sanchr_Contacts_GetBlockedListRequest()

        SanchrLogger.network.info("ContactDataSource: getBlockedList")
        let response = try await contactClient.getBlockedList(request)

        return response.blockedUserIds
    }

    // MARK: - Hashing

    /// Hashes a phone number using SHA-256 for privacy-preserving contact discovery.
    static func hashPhoneNumber(_ phoneNumber: String) -> Data {
        let normalized = normalizePhoneNumber(phoneNumber)
        let data = Data(normalized.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    /// Normalize a phone number for comparison — strips whitespace,
    /// dashes, and parentheses. Keeps the leading `+` and digits so
    /// `"+91 98765 43210"` matches `"+919876543210"`. MUST be used
    /// everywhere a phone needs to match another phone (contact lookup,
    /// bubble viewer resolution) so there is exactly one definition of
    /// "same phone" in the app.
    static func normalizePhoneNumber(_ phoneNumber: String) -> String {
        phoneNumber
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    /// Extracts the country calling code from the signed-in user's own E.164
    /// number, so address-book entries saved without a country code are expanded
    /// to the user's own country.
    ///
    /// Uses the longest matching code from a table of the multi-digit ones —
    /// they are the cases a naive fixed-width split gets wrong — and otherwise
    /// falls back to the leading digit, which covers +1 and +7.
    static func callingCode(fromE164 number: String) -> String {
        let digits = number.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }

        // Codes that are 2 or 3 digits long; ordered longest-first at match time.
        let knownCodes = [
            "998", "996", "995", "994", "993", "992", "977", "976", "975", "974",
            "973", "972", "971", "970", "968", "967", "966", "965", "964", "963",
            "962", "961", "960", "886", "880", "856", "855", "853", "852", "850",
            "692", "691", "690", "689", "688", "687", "686", "685", "684", "683",
            "682", "681", "680", "679", "678", "677", "676", "675", "674", "673",
            "672", "670", "599", "598", "597", "596", "595", "594", "593", "592",
            "591", "590", "509", "508", "507", "506", "505", "504", "503", "502",
            "501", "500", "423", "421", "420", "389", "387", "386", "385", "383",
            "382", "381", "380", "378", "377", "376", "375", "374", "373", "372",
            "371", "370", "359", "358", "357", "356", "355", "354", "353", "352",
            "351", "350", "299", "298", "297", "296", "295", "294", "293", "292",
            "291", "290", "269", "268", "267", "266", "265", "264", "263", "262",
            "261", "260", "258", "257", "256", "255", "254", "253", "252", "251",
            "250", "249", "248", "247", "246", "245", "244", "243", "242", "241",
            "240", "239", "238", "237", "236", "235", "234", "233", "232", "231",
            "230", "229", "228", "227", "226", "225", "224", "223", "222", "221",
            "220", "218", "216", "213", "212", "211", "98", "95", "94", "93",
            "92", "91", "90", "86", "84", "82", "81", "66", "65", "64", "63",
            "62", "61", "60", "58", "57", "56", "55", "54", "53", "52", "51",
            "49", "48", "47", "46", "45", "44", "43", "41", "40", "39", "36",
            "34", "33", "32", "31", "30", "27", "20",
        ]
        for code in knownCodes.sorted(by: { $0.count > $1.count })
        where digits.hasPrefix(code) && digits.count > code.count {
            return "+" + code
        }
        return "+" + String(digits.prefix(1))
    }

    /// How many digits a national number has in the signed-in user's country,
    /// worked out from their own registered number.
    ///
    /// This is what makes a locally-saved number unambiguous. Without it, a
    /// ten-digit Indian mobile that happens to begin "91" — a real allocated
    /// series — is indistinguishable from a country code followed by eight
    /// digits, and gets expanded as the latter.
    ///
    /// Derived rather than tabulated: the user's own number is already known to
    /// be a valid national number for their country, so it is a better source
    /// than a table this app would have to keep current for every country.
    static func nationalNumberLength(ofE164 number: String) -> Int? {
        let digits = number.filter(\.isNumber)
        let code = callingCode(fromE164: number).filter(\.isNumber)
        guard !digits.isEmpty, !code.isEmpty, digits.count > code.count else { return nil }

        // No country has national numbers this short. A tiny value here would
        // be worse than none: it would make the length test below fire on
        // fragments and expand them as if they were whole numbers.
        let length = digits.count - code.count
        return length >= 4 ? length : nil
    }

    /// Converts an address-book number to the E.164 form the server registered.
    ///
    /// Accounts are stored as country code + subscriber number ("+919569740653"),
    /// but people save contacts however they please — "9569740653",
    /// "095697 40653", "0091-9569740653". Discovery blinds this string, so a
    /// local-format entry simply never matches its own account and the sync
    /// reports zero contacts. Normalizing to E.164 first is what makes the
    /// match possible.
    ///
    /// `defaultCallingCode` is the caller's own country code (e.g. "+91"),
    /// applied to numbers that carry no country information of their own.
    /// - Parameter nationalNumberLength: how many digits a national number has
    ///   in the user's country. Supplying it is what disambiguates a number
    ///   that begins with its own country's calling code; without it the older,
    ///   prefix-only behaviour applies.
    static func e164PhoneNumber(
        _ phoneNumber: String,
        defaultCallingCode: String,
        nationalNumberLength: Int? = nil
    ) -> String? {
        var digits = normalizePhoneNumber(phoneNumber)
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")

        // Already international.
        if digits.hasPrefix("+") {
            let rest = digits.dropFirst().filter(\.isNumber)
            return rest.isEmpty ? nil : "+" + rest
        }

        // "00" is the other international prefix in common use.
        if digits.hasPrefix("00") {
            let rest = digits.dropFirst(2).filter(\.isNumber)
            return rest.isEmpty ? nil : "+" + rest
        }

        digits = String(digits.filter(\.isNumber))
        guard !digits.isEmpty else { return nil }

        let callingDigits = defaultCallingCode.filter(\.isNumber)
        guard !callingDigits.isEmpty else { return nil }

        // A leading trunk zero ("095697 40653") is national-dialling only and is
        // dropped when the number goes international.
        if digits.hasPrefix("0") {
            digits = String(digits.drop(while: { $0 == "0" }))
            guard !digits.isEmpty else { return nil }
        }

        // A number of exactly the national length is a national number, even
        // when it happens to start with its own country's calling code.
        //
        // This check has to come first. India's calling code is 91 and 91 is
        // also a valid mobile prefix there, so "9198765432" satisfies the
        // country-code test below and was expanded to "+9198765432" — ten
        // digits where twelve were needed. Those contacts could never match
        // their own account, and nothing said so.
        if let nationalNumberLength, digits.count == nationalNumberLength {
            return "+" + callingDigits + digits
        }

        // Some entries are saved with the country code but no "+".
        if digits.hasPrefix(callingDigits), digits.count > callingDigits.count {
            return "+" + digits
        }

        return "+" + callingDigits + digits
    }

    // MARK: - Mapping

    /// Maps a gRPC MatchedContact to the domain User model.
    static func mapMatchedContactToUser(_ matched: Sanchr_Contacts_MatchedContact) -> User {
        User(
            id: matched.userID,
            phoneNumber: matched.phoneNumber,
            displayName: matched.displayName,
            avatarURL: matched.avatarURL.isEmpty ? nil : URL(string: matched.avatarURL),
            bio: matched.statusText.isEmpty ? nil : matched.statusText,
            isVerified: true,
            lastSeen: nil,
            identityKeyFingerprint: nil,
            status: .offline
        )
    }

    /// Maps a gRPC Contact to the domain User model.
    static func mapContactToUser(_ contact: Sanchr_Contacts_Contact) -> User {
        User(
            id: contact.userID,
            phoneNumber: contact.phoneNumber,
            displayName: contact.displayName,
            avatarURL: contact.avatarURL.isEmpty ? nil : URL(string: contact.avatarURL),
            bio: contact.statusText.isEmpty ? nil : contact.statusText,
            isVerified: true,
            lastSeen: nil,
            identityKeyFingerprint: nil,
            status: .offline
        )
    }
}

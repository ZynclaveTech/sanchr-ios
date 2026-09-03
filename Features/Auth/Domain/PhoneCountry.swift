import Foundation

/// A country the sign-in screen can register from: its ISO region, calling
/// code, and enough about its numbering plan to validate and format what
/// the user types. Ten hardcoded countries used to be the whole list, so
/// anyone elsewhere could not create an account.
struct PhoneCountry: Identifiable, Hashable, Sendable {
    let region: String
    let callingCode: String
    /// Accepted lengths of the national number (after the trunk zero is
    /// dropped). A range where the plan is not fixed-length.
    let nationalLength: ClosedRange<Int>

    var id: String { region }

    /// "+91" → "91".
    var callingDigits: String { callingCode.filter(\.isNumber) }

    var name: String {
        Locale.current.localizedString(forRegionCode: region) ?? region
    }

    /// Regional-indicator flag for the ISO code.
    var flag: String {
        String(region.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(Character.init))
    }

    /// Countries in the North American Numbering Plan share +1 and have no
    /// trunk prefix; everywhere else a leading 0 is national-dialling only.
    var usesTrunkZero: Bool { callingCode != "+1" }

    /// Digits the user typed, made into a national number: non-digits and a
    /// leading trunk zero removed, capped at the plan's longest length.
    func nationalNumber(from input: String) -> String {
        var digits = input.filter(\.isNumber)
        if usesTrunkZero, digits.hasPrefix("0") {
            digits = String(digits.drop(while: { $0 == "0" }))
        }
        return String(digits.prefix(nationalLength.upperBound))
    }

    func isValid(nationalNumber: String) -> Bool {
        nationalLength.contains(nationalNumber.count)
            && nationalNumber.allSatisfy(\.isNumber)
            && nationalNumber.first != "0"
    }

    /// E.164 for the server: "+" + calling code + national number.
    func e164(nationalNumber: String) -> String {
        callingCode + nationalNumber
    }

    /// Display formatting for the field, grouped the way people in that
    /// country write numbers so a typo is easier to spot.
    func format(nationalNumber digits: String) -> String {
        switch callingCode {
        case "+1":
            // (555) 123-4567
            let a = digits.prefix(3), b = digits.dropFirst(3).prefix(3), c = digits.dropFirst(6).prefix(4)
            var out = ""
            if !a.isEmpty { out += digits.count > 3 ? "(\(a)) " : String(a) }
            if !b.isEmpty { out += String(b) }
            if !c.isEmpty { out += "-\(c)" }
            return out
        case "+91":
            // 98765 43210
            return groups(digits, sizes: [5, 5])
        default:
            return groups(digits, sizes: [3, 3, 3, 3, 3])
        }
    }

    /// What an example number looks like, as the field's placeholder.
    var placeholder: String {
        switch callingCode {
        case "+1": return "(555) 123-4567"
        case "+91": return "98765 43210"
        case "+44": return "7911 123456"
        default: return format(nationalNumber: String(repeating: "5", count: nationalLength.lowerBound))
        }
    }

    private func groups(_ digits: String, sizes: [Int]) -> String {
        var rest = Substring(digits), parts: [String] = []
        for size in sizes where !rest.isEmpty {
            parts.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts.joined(separator: " ")
    }

    // MARK: - Lookup

    static func withRegion(_ region: String) -> PhoneCountry? {
        all.first { $0.region == region }
    }

    /// The country to preselect: the device's region when it is in the
    /// table, else India (the launch market), else the first entry.
    static var detected: PhoneCountry {
        let region = Locale.current.region?.identifier ?? ""
        return withRegion(region) ?? withRegion("IN") ?? all[0]
    }

    /// Every ITU-assigned country and territory, sorted by localized name.
    static let all: [PhoneCountry] = table
        .map { PhoneCountry(region: $0.0, callingCode: "+" + $0.1, nationalLength: $0.2) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    /// ISO region, calling code, accepted national-number lengths. Lengths
    /// follow each plan's mobile numbers, with a range where the plan mixes
    /// lengths; unknown plans accept 4…12 so nobody is locked out.
    private static let table: [(String, String, ClosedRange<Int>)] = [
        ("AF", "93", 9...9), ("AL", "355", 9...9), ("DZ", "213", 9...9), ("AS", "1", 10...10), ("AD", "376", 6...9),
        ("AO", "244", 9...9), ("AI", "1", 10...10), ("AG", "1", 10...10), ("AR", "54", 10...10), ("AM", "374", 8...8),
        ("AW", "297", 7...7), ("AU", "61", 9...9), ("AT", "43", 10...13), ("AZ", "994", 9...9), ("BS", "1", 10...10),
        ("BH", "973", 8...8), ("BD", "880", 10...10), ("BB", "1", 10...10), ("BY", "375", 9...9), ("BE", "32", 9...9),
        ("BZ", "501", 7...7), ("BJ", "229", 8...10), ("BM", "1", 10...10), ("BT", "975", 8...8), ("BO", "591", 8...8),
        ("BA", "387", 8...8), ("BW", "267", 8...8), ("BR", "55", 10...11), ("IO", "246", 7...7), ("VG", "1", 10...10),
        ("BN", "673", 7...7), ("BG", "359", 9...9), ("BF", "226", 8...8), ("BI", "257", 8...8), ("KH", "855", 8...9),
        ("CM", "237", 9...9), ("CA", "1", 10...10), ("CV", "238", 7...7), ("KY", "1", 10...10), ("CF", "236", 8...8),
        ("TD", "235", 8...8), ("CL", "56", 9...9), ("CN", "86", 11...11), ("CO", "57", 10...10), ("KM", "269", 7...7),
        ("CG", "242", 9...9), ("CD", "243", 9...9), ("CK", "682", 5...5), ("CR", "506", 8...8), ("CI", "225", 10...10),
        ("HR", "385", 9...9), ("CU", "53", 8...8), ("CW", "599", 7...8), ("CY", "357", 8...8), ("CZ", "420", 9...9),
        ("DK", "45", 8...8), ("DJ", "253", 8...8), ("DM", "1", 10...10), ("DO", "1", 10...10), ("EC", "593", 9...9),
        ("EG", "20", 10...10), ("SV", "503", 8...8), ("GQ", "240", 9...9), ("ER", "291", 7...7), ("EE", "372", 7...8),
        ("SZ", "268", 8...8), ("ET", "251", 9...9), ("FK", "500", 5...5), ("FO", "298", 6...6), ("FJ", "679", 7...7),
        ("FI", "358", 6...10), ("FR", "33", 9...9), ("GF", "594", 9...9), ("PF", "689", 8...8), ("GA", "241", 7...8),
        ("GM", "220", 7...7), ("GE", "995", 9...9), ("DE", "49", 10...11), ("GH", "233", 9...9), ("GI", "350", 8...8),
        ("GR", "30", 10...10), ("GL", "299", 6...6), ("GD", "1", 10...10), ("GP", "590", 9...9), ("GU", "1", 10...10),
        ("GT", "502", 8...8), ("GG", "44", 10...10), ("GN", "224", 9...9), ("GW", "245", 9...9), ("GY", "592", 7...7),
        ("HT", "509", 8...8), ("HN", "504", 8...8), ("HK", "852", 8...8), ("HU", "36", 9...9), ("IS", "354", 7...7),
        ("IN", "91", 10...10), ("ID", "62", 9...12), ("IR", "98", 10...10), ("IQ", "964", 10...10), ("IE", "353", 9...9),
        ("IM", "44", 10...10), ("IL", "972", 9...9), ("IT", "39", 9...10), ("JM", "1", 10...10), ("JP", "81", 10...10),
        ("JE", "44", 10...10), ("JO", "962", 9...9), ("KZ", "7", 10...10), ("KE", "254", 9...9), ("KI", "686", 8...8),
        ("XK", "383", 8...8), ("KW", "965", 8...8), ("KG", "996", 9...9), ("LA", "856", 9...10), ("LV", "371", 8...8),
        ("LB", "961", 7...8), ("LS", "266", 8...8), ("LR", "231", 8...9), ("LY", "218", 9...9), ("LI", "423", 7...9),
        ("LT", "370", 8...8), ("LU", "352", 9...9), ("MO", "853", 8...8), ("MG", "261", 9...9), ("MW", "265", 9...9),
        ("MY", "60", 9...10), ("MV", "960", 7...7), ("ML", "223", 8...8), ("MT", "356", 8...8), ("MH", "692", 7...7),
        ("MQ", "596", 9...9), ("MR", "222", 8...8), ("MU", "230", 8...8), ("YT", "262", 9...9), ("MX", "52", 10...10),
        ("FM", "691", 7...7), ("MD", "373", 8...8), ("MC", "377", 8...9), ("MN", "976", 8...8), ("ME", "382", 8...8),
        ("MS", "1", 10...10), ("MA", "212", 9...9), ("MZ", "258", 9...9), ("MM", "95", 8...10), ("NA", "264", 9...9),
        ("NR", "674", 7...7), ("NP", "977", 10...10), ("NL", "31", 9...9), ("NC", "687", 6...6), ("NZ", "64", 8...10),
        ("NI", "505", 8...8), ("NE", "227", 8...8), ("NG", "234", 10...10), ("NU", "683", 4...4), ("NF", "672", 6...6),
        ("KP", "850", 10...10), ("MK", "389", 8...8), ("MP", "1", 10...10), ("NO", "47", 8...8), ("OM", "968", 8...8),
        ("PK", "92", 10...10), ("PW", "680", 7...7), ("PS", "970", 9...9), ("PA", "507", 8...8), ("PG", "675", 8...8),
        ("PY", "595", 9...9), ("PE", "51", 9...9), ("PH", "63", 10...10), ("PL", "48", 9...9), ("PT", "351", 9...9),
        ("PR", "1", 10...10), ("QA", "974", 8...8), ("RE", "262", 9...9), ("RO", "40", 9...9), ("RU", "7", 10...10),
        ("RW", "250", 9...9), ("BL", "590", 9...9), ("SH", "290", 4...5), ("KN", "1", 10...10), ("LC", "1", 10...10),
        ("MF", "590", 9...9), ("PM", "508", 6...6), ("VC", "1", 10...10), ("WS", "685", 5...7), ("SM", "378", 6...10),
        ("ST", "239", 7...7), ("SA", "966", 9...9), ("SN", "221", 9...9), ("RS", "381", 8...9), ("SC", "248", 7...7),
        ("SL", "232", 8...8), ("SG", "65", 8...8), ("SX", "1", 10...10), ("SK", "421", 9...9), ("SI", "386", 8...8),
        ("SB", "677", 5...7), ("SO", "252", 8...9), ("ZA", "27", 9...9), ("KR", "82", 9...10), ("SS", "211", 9...9),
        ("ES", "34", 9...9), ("LK", "94", 9...9), ("SD", "249", 9...9), ("SR", "597", 6...7), ("SE", "46", 7...10),
        ("CH", "41", 9...9), ("SY", "963", 9...9), ("TW", "886", 9...9), ("TJ", "992", 9...9), ("TZ", "255", 9...9),
        ("TH", "66", 9...9), ("TL", "670", 7...8), ("TG", "228", 8...8), ("TK", "690", 4...4), ("TO", "676", 5...7),
        ("TT", "1", 10...10), ("TN", "216", 8...8), ("TR", "90", 10...10), ("TM", "993", 8...8), ("TC", "1", 10...10),
        ("TV", "688", 5...6), ("UG", "256", 9...9), ("UA", "380", 9...9), ("AE", "971", 9...9), ("GB", "44", 10...10),
        ("US", "1", 10...10), ("UY", "598", 8...8), ("VI", "1", 10...10), ("UZ", "998", 9...9), ("VU", "678", 5...7),
        ("VA", "39", 9...10), ("VE", "58", 10...10), ("VN", "84", 9...10), ("WF", "681", 6...6), ("YE", "967", 9...9),
        ("ZM", "260", 9...9), ("ZW", "263", 9...9),
    ]
}

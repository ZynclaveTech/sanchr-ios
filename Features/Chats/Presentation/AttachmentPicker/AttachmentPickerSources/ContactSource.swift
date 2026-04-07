import Foundation
import Contacts
import ContactsUI
import UIKit

enum ContactSource {

    /// The ONLY path from CNContact -> StrippedContact.
    /// Drops avatar, postal, social, org, notes, birthday, URLs, IM.
    static func strip(_ contact: CNContact) -> StrippedContact? {
        let given = contact.givenName.trimmingCharacters(in: .whitespaces)
        let family = contact.familyName.trimmingCharacters(in: .whitespaces)
        let name = [given, family].filter { !$0.isEmpty }.joined(separator: " ")

        let phones = contact.phoneNumbers
            .map { $0.value.stringValue }
            .compactMap(Self.normalizeE164(_:))

        let emails = contact.emailAddresses
            .map { ($0.value as String).lowercased() }
            .filter { $0.contains("@") }

        guard !phones.isEmpty || !emails.isEmpty else { return nil }
        let displayName = name.isEmpty ? (emails.first ?? phones.first ?? "Contact") : name
        return StrippedContact(displayName: displayName, phoneNumbers: phones, emails: emails)
    }

    static func normalizeE164(_ raw: String) -> String? {
        let hasPlus = raw.hasPrefix("+")
        let digits = raw.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init)
        let digitString = String(digits)
        guard !digitString.isEmpty else { return nil }
        if hasPlus { return "+" + digitString }
        let region = Locale.current.region?.identifier ?? "US"
        let cc = Self.countryCode(for: region) ?? "1"
        return "+" + cc + digitString
    }

    private static func countryCode(for region: String) -> String? {
        ["US": "1", "IN": "91", "GB": "44", "CA": "1", "AU": "61"][region]
    }
}

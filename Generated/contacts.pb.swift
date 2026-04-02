import Foundation

// MARK: - vync.contacts messages
// Generated from Proto/contacts.proto — DO NOT EDIT

struct Vync_Contacts_SyncContactsRequest: Codable, Sendable {
    var phoneHashes: [Data] = []

    enum CodingKeys: String, CodingKey {
        case phoneHashes = "phone_hashes"
    }
}

struct Vync_Contacts_SyncContactsResponse: Codable, Sendable {
    var matches: [Vync_Contacts_MatchedContact] = []
}

struct Vync_Contacts_MatchedContact: Codable, Sendable, Hashable {
    var userID: String = ""
    var displayName: String = ""
    var avatarURL: String = ""
    var statusText: String = ""

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case statusText = "status_text"
    }
}

struct Vync_Contacts_GetContactsRequest: Codable, Sendable {}

struct Vync_Contacts_GetContactsResponse: Codable, Sendable {
    var contacts: [Vync_Contacts_Contact] = []
}

struct Vync_Contacts_Contact: Codable, Sendable, Hashable {
    var userID: String = ""
    var displayName: String = ""
    var avatarURL: String = ""
    var statusText: String = ""
    var isBlocked: Bool = false
    var isFavorite: Bool = false

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case statusText = "status_text"
        case isBlocked = "is_blocked"
        case isFavorite = "is_favorite"
    }
}

struct Vync_Contacts_BlockContactRequest: Codable, Sendable {
    var contactUserID: String = ""

    enum CodingKeys: String, CodingKey {
        case contactUserID = "contact_user_id"
    }
}

struct Vync_Contacts_BlockContactResponse: Codable, Sendable {}

struct Vync_Contacts_UnblockContactRequest: Codable, Sendable {
    var contactUserID: String = ""

    enum CodingKeys: String, CodingKey {
        case contactUserID = "contact_user_id"
    }
}

struct Vync_Contacts_UnblockContactResponse: Codable, Sendable {}

struct Vync_Contacts_GetBlockedListRequest: Codable, Sendable {}

struct Vync_Contacts_GetBlockedListResponse: Codable, Sendable {
    var blockedUserIDs: [String] = []

    enum CodingKeys: String, CodingKey {
        case blockedUserIDs = "blocked_user_ids"
    }
}

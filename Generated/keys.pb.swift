import Foundation

// MARK: - vync.keys messages
// Generated from Proto/keys.proto — DO NOT EDIT

struct Vync_Keys_SignedPreKey: Codable, Sendable, Hashable {
    var keyID: Int32 = 0
    var publicKey: Data = Data()
    var signature: Data = Data()

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case publicKey = "public_key"
        case signature
    }
}

struct Vync_Keys_OneTimePreKey: Codable, Sendable, Hashable {
    var keyID: Int32 = 0
    var publicKey: Data = Data()

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case publicKey = "public_key"
    }
}

struct Vync_Keys_KeyBundle: Codable, Sendable {
    var identityPublicKey: Data = Data()
    var signedPreKey: Vync_Keys_SignedPreKey?
    var oneTimePreKeys: [Vync_Keys_OneTimePreKey] = []

    enum CodingKeys: String, CodingKey {
        case identityPublicKey = "identity_public_key"
        case signedPreKey = "signed_pre_key"
        case oneTimePreKeys = "one_time_pre_keys"
    }
}

struct Vync_Keys_UploadKeyBundleResponse: Codable, Sendable {}

struct Vync_Keys_GetPreKeyBundleRequest: Codable, Sendable {
    var userID: String = ""
    var deviceID: Int32 = 0

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case deviceID = "device_id"
    }
}

struct Vync_Keys_PreKeyBundleResponse: Codable, Sendable {
    var identityPublicKey: Data = Data()
    var signedPreKey: Vync_Keys_SignedPreKey?
    var oneTimePreKey: Vync_Keys_OneTimePreKey?
    var deviceID: Int32 = 0

    enum CodingKeys: String, CodingKey {
        case identityPublicKey = "identity_public_key"
        case signedPreKey = "signed_pre_key"
        case oneTimePreKey = "one_time_pre_key"
        case deviceID = "device_id"
    }
}

struct Vync_Keys_UploadOneTimePreKeysRequest: Codable, Sendable {
    var keys: [Vync_Keys_OneTimePreKey] = []
}

struct Vync_Keys_PreKeyCountResponse: Codable, Sendable {
    var count: Int32 = 0
}

struct Vync_Keys_GetPreKeyCountRequest: Codable, Sendable {}

struct Vync_Keys_GetUserDevicesRequest: Codable, Sendable {
    var userID: String = ""

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
    }
}

struct Vync_Keys_GetUserDevicesResponse: Codable, Sendable {
    var deviceIDs: [Int32] = []

    enum CodingKeys: String, CodingKey {
        case deviceIDs = "device_ids"
    }
}

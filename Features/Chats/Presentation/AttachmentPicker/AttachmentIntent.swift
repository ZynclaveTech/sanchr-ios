import Foundation

enum AttachmentIntent: Sendable {
    case photoLibrary([PickedMedia])
    case capturedMedia(CapturedMedia)
    case vaultItem(VaultItem)          // existing domain model
    case file(PickedFile)
    case contact(StrippedContact)
    case location(LocationPayload)
}

struct PickedMedia: Sendable, Identifiable, Equatable {
    enum Kind: Sendable, Equatable { case photo, video }
    let id: UUID
    let kind: Kind
    let data: Data
    let fileURL: URL?
    let originalFilename: String?
    let mimeType: String
    let width: Int
    let height: Int
    let durationSeconds: Double?
}

struct CapturedMedia: Sendable, Equatable {
    let kind: PickedMedia.Kind
    let data: Data
    let capturedAt: Date
    let width: Int
    let height: Int
    let durationSeconds: Double?
}

struct PickedFile: Sendable, Equatable {
    let url: URL
    let filename: String
    let sizeBytes: Int64
    let mimeType: String
}

// Temporary stubs — replaced in Task 2 / Task 3
struct StrippedContact: Sendable, Equatable {}
struct LocationPayload: Sendable, Equatable {}

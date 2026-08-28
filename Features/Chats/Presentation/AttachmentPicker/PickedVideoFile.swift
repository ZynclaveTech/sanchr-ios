import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A video received from `PhotosPicker` as a *file* rather than as bytes.
///
/// `loadTransferable(type: Data.self)` reads the whole clip into memory before
/// anything can be written to disk. A minute of 4K is several hundred
/// megabytes, so a large video risks a memory spike and termination on the
/// very devices most likely to have shot it.
///
/// A `FileRepresentation` hands over a URL instead, which is copied straight
/// out to a temp file — peak memory stays flat regardless of clip length. This
/// matches what the in-app attachment sheet already does through
/// `PHAssetResourceManager.writeData`; the system-picker path was the one
/// still loading everything at once.
struct PickedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            // The received file is temporary and reclaimed as soon as this
            // returns, so it has to be copied rather than referenced.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).mp4")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedVideoFile(url: destination)
        }
    }
}

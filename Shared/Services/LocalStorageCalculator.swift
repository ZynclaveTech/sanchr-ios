import Foundation
import SanchrShared

/// Storage actually occupied by this app on this device.
struct LocalStorageUsage: Equatable, Sendable {
    var photosBytes: Int64 = 0
    var videosBytes: Int64 = 0
    var documentsBytes: Int64 = 0
    var voiceBytes: Int64 = 0
    /// Message database, Signal state, and anything else that is not media.
    var otherBytes: Int64 = 0
    /// Free space left on the device, used as the reference for the usage bar.
    var deviceFreeBytes: Int64 = 0

    var totalBytes: Int64 {
        photosBytes + videosBytes + documentsBytes + voiceBytes + otherBytes
    }
}

/// Measures on-device storage for the Storage & Data screen.
///
/// The server cannot compute this: media types live inside forward-secure
/// encrypted vault metadata, so `GetStorageUsage` returns zeros by design and
/// the screen previously reported that the app used no storage at all. Since
/// every byte is local anyway — the encrypted database, the media cache — the
/// honest measurement is a walk of the app's own container.
enum LocalStorageCalculator {
    /// Extensions grouped the way the breakdown presents them. Voice notes are
    /// distinguished from other audio by living in the voice-note cache with an
    /// `m4a` extension, which is what the recorder writes.
    private static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff",
    ]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    private static let voiceExtensions: Set<String> = ["m4a", "caf", "aac", "opus", "amr"]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "csv",
        "zip", "json",
    ]

    static func calculate() async -> LocalStorageUsage {
        await Task.detached(priority: .utility) { measure() }.value
    }

    private static func measure() -> LocalStorageUsage {
        var usage = LocalStorageUsage()
        let fileManager = FileManager.default

        // Media cache: classify each cached file by extension.
        let mediaRoot = AppGroup.mediaCacheURL
        if let enumerator = fileManager.enumerator(
            at: mediaRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard let size = fileSize(of: url, fileManager: fileManager) else { continue }
                switch url.pathExtension.lowercased() {
                case let ext where photoExtensions.contains(ext):
                    usage.photosBytes += size
                case let ext where videoExtensions.contains(ext):
                    usage.videosBytes += size
                case let ext where voiceExtensions.contains(ext):
                    usage.voiceBytes += size
                case let ext where documentExtensions.contains(ext):
                    usage.documentsBytes += size
                default:
                    // Unknown extension: still real storage the user is paying
                    // for, so count it rather than silently under-reporting.
                    usage.otherBytes += size
                }
            }
        }

        // Everything else in the App Group container that is not the media cache:
        // the encrypted database (plus its -wal/-shm sidecars) and Signal state.
        let container = AppGroup.containerURL
        if let enumerator = fileManager.enumerator(
            at: container,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            let mediaPath = mediaRoot.standardizedFileURL.path
            for case let url as URL in enumerator {
                guard !url.standardizedFileURL.path.hasPrefix(mediaPath),
                    let size = fileSize(of: url, fileManager: fileManager)
                else { continue }
                usage.otherBytes += size
            }
        }

        usage.deviceFreeBytes = deviceFreeSpace(fileManager: fileManager)
        return usage
    }

    private static func fileSize(of url: URL, fileManager: FileManager) -> Int64? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true,
            let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    private static func deviceFreeSpace(fileManager: FileManager) -> Int64 {
        guard
            let values = try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return 0 }
        return Int64(capacity)
    }
}

import Foundation

enum VoiceRecorderError: Error, Equatable {
    case permissionDenied
    case sessionFailed(String)
    case recordingTooShort
    case fileMissing
    case decodingFailed
}

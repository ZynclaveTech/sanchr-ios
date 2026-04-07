import Foundation
import SanchrShared

enum VoiceRecorderError: Error, Equatable {
    case permissionDenied
    case sessionFailed(String)
    case recordingTooShort
    case fileMissing
    case decodingFailed
}

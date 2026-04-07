import Foundation
import AVFoundation

/// Abstraction over AVAudioRecorder so VoiceRecorderTests can run on
/// CI/simulator without touching the real audio hardware.
protocol AudioRecording: AnyObject {
    var isRecording: Bool { get }
    var url: URL { get }
    var currentTime: TimeInterval { get }
    var averagePower: Float { get }   // dB, -160...0
    func record() -> Bool
    func stop()
    func updateMeters()
    func deleteRecording() -> Bool
}

final class RealAudioRecorder: AudioRecording {

    nonisolated(unsafe) static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32000
    ]

    private let recorder: AVAudioRecorder

    init(url: URL) throws {
        self.recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        self.recorder.isMeteringEnabled = true
        self.recorder.prepareToRecord()
    }

    var isRecording: Bool { recorder.isRecording }
    var url: URL { recorder.url }
    var currentTime: TimeInterval { recorder.currentTime }
    var averagePower: Float { recorder.averagePower(forChannel: 0) }
    func record() -> Bool { recorder.record() }
    func stop() { recorder.stop() }
    func updateMeters() { recorder.updateMeters() }
    func deleteRecording() -> Bool { recorder.deleteRecording() }
}

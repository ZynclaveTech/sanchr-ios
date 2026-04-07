import XCTest
import AVFoundation
import SanchrShared
@testable import Sanchr

@MainActor
final class VoicePlaybackControllerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func test_playingNewClip_pausesPreviousClip() async throws {
        let controller = VoicePlaybackController()
        let url = try Self.writeSilentM4A(seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }

        try controller.play(url: url, messageId: "msg-A")
        XCTAssertEqual(controller.currentlyPlayingMessageId, "msg-A")

        try controller.play(url: url, messageId: "msg-B")
        XCTAssertEqual(controller.currentlyPlayingMessageId, "msg-B")
    }

    private static func writeSilentM4A(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-\(UUID().uuidString).m4a")
        let sampleRate: Double = 44100
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = AVAudioFrameCount(sampleRate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
        buf.frameLength = total
        // floatChannelData is already zero-initialized.
        try file.write(from: buf)
        return url
    }
}

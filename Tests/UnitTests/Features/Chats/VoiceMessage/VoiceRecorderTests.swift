import AVFoundation
import XCTest

@testable import Sanchr

final class VoiceRecorderTests: XCTestCase {

    final class MockAudioRecording: AudioRecording, @unchecked Sendable {
        var isRecording: Bool = false
        let url: URL
        var currentTime: TimeInterval = 0
        var averagePower: Float = -30
        var recordCalls = 0
        var stopCalls = 0
        var deleteCalls = 0

        init(url: URL) { self.url = url }

        func record() -> Bool {
            isRecording = true
            recordCalls += 1
            return true
        }
        func stop() {
            isRecording = false
            stopCalls += 1
        }
        func updateMeters() {}
        func deleteRecording() -> Bool {
            deleteCalls += 1
            return true
        }
    }

    func test_settings_matchSpec() {
        let settings = RealAudioRecorder.settings
        XCTAssertEqual(settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(settings[AVSampleRateKey] as? Int, 44100)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 32000)
    }

    func test_outputURL_isInTempDir_withM4aExtension() {
        let url = VoiceRecorder.makeOutputURL()
        XCTAssertTrue(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertEqual(url.pathExtension, "m4a")
    }

    func test_cancel_callsDeleteAndStop() async {
        let mock = MockAudioRecording(url: VoiceRecorder.makeOutputURL())
        let recorder = VoiceRecorder(makeRecorder: { _ in mock })
        try? await recorder.startForTesting()
        await recorder.cancel()
        XCTAssertEqual(mock.stopCalls, 1)
        XCTAssertEqual(mock.deleteCalls, 1)
    }

    func test_stop_underMinDuration_throwsRecordingTooShort() async {
        let mock = MockAudioRecording(url: VoiceRecorder.makeOutputURL())
        mock.currentTime = 0.4
        let recorder = VoiceRecorder(makeRecorder: { _ in mock })
        try? await recorder.startForTesting()
        do {
            _ = try await recorder.stop()
            XCTFail("expected recordingTooShort")
        } catch VoiceRecorderError.recordingTooShort {
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

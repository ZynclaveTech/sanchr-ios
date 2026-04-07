import XCTest
import AVFoundation
@testable import Sanchr

final class VoiceWaveformDecoderTests: XCTestCase {

    func test_decode_sineWave_producesUniformBins() async throws {
        let url = try Self.writeSineWaveM4A(durationSeconds: 2.0, frequency: 1000)
        defer { try? FileManager.default.removeItem(at: url) }

        let bins = try await VoiceWaveformDecoder.decode(url: url, bins: 64)
        XCTAssertEqual(bins.count, 64)
        let avg = bins.reduce(0, +) / Float(bins.count)
        XCTAssertGreaterThan(avg, 0.05, "expected non-trivial energy")
        for b in bins {
            XCTAssertGreaterThan(b, 0)
            XCTAssertLessThanOrEqual(b, 1)
        }
    }

    private static func writeSineWaveM4A(durationSeconds: Double, frequency: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sine-\(UUID().uuidString).m4a")
        let sampleRate: Double = 44100
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        let total = AVAudioFrameCount(sampleRate * durationSeconds)
        let chunk: AVAudioFrameCount = 1024
        var written: AVAudioFrameCount = 0
        while written < total {
            let n = min(chunk, total - written)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
            buf.frameLength = n
            let ptr = buf.floatChannelData![0]
            for i in 0..<Int(n) {
                let t = Double(Int(written) + i) / sampleRate
                ptr[i] = Float(sin(2 * .pi * frequency * t)) * 0.5
            }
            try file.write(from: buf)
            written += n
        }
        return url
    }
}

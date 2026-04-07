import Foundation
import AVFoundation
import SanchrShared

enum VoiceWaveformDecoder {

    /// Decodes an audio file at `url` into `bins` normalized energy buckets (0...1).
    /// Uses AVAssetReader → PCM Int16 → bucket-averaged absolute value.
    static func decode(url: URL, bins: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw VoiceRecorderError.decodingFailed }
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        guard reader.startReading() else { throw VoiceRecorderError.decodingFailed }

        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            guard let p = dataPointer else { continue }
            let count = totalLength / MemoryLayout<Int16>.size
            p.withMemoryRebound(to: Int16.self, capacity: count) { intPtr in
                samples.append(contentsOf: UnsafeBufferPointer(start: intPtr, count: count))
            }
            CMSampleBufferInvalidate(buffer)
        }

        guard !samples.isEmpty else { throw VoiceRecorderError.decodingFailed }
        return bucketAverage(samples: samples, bins: bins)
    }

    private static func bucketAverage(samples: [Int16], bins: Int) -> [Float] {
        guard bins > 0, !samples.isEmpty else { return [] }
        let perBin = max(1, samples.count / bins)
        var result: [Float] = []
        result.reserveCapacity(bins)
        let maxAmplitude = Float(Int16.max)
        for i in 0..<bins {
            let start = i * perBin
            let end = min(start + perBin, samples.count)
            if start >= end { result.append(0); continue }
            var sum: Float = 0
            for j in start..<end {
                sum += abs(Float(samples[j]))
            }
            let avg = sum / Float(end - start)
            result.append(min(1, avg / maxAmplitude * 2))
        }
        return result
    }
}

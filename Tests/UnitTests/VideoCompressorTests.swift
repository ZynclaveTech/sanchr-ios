import AVFoundation
import UIKit
import XCTest
import SanchrShared

@testable import Sanchr

/// End-to-end check on a real video file. The policy tests cover the decision;
/// this covers the export actually producing something playable, because a
/// compressor that silently emits a corrupt file is worse than none at all.
final class VideoCompressorTests: XCTestCase {

    /// Writes a short 1080p clip with large moving blocks.
    ///
    /// Content matters here. A flat colour compresses to almost nothing and
    /// falls under the skip threshold, so the test would assert nothing. Pure
    /// per-pixel noise is the opposite problem: it is incompressible, so
    /// downscaling saves little and the policy rightly declines the result —
    /// which also asserts nothing about the keep path. Large blocks that move
    /// between frames behave like real footage: big enough to exceed the
    /// threshold, compressible enough that 720p is a genuine saving.
    private func makeVideo(
        size: CGSize = CGSize(width: 1920, height: 1080),
        seconds: Int = 4
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        let renderer = UIGraphicsImageRenderer(size: size)
        for frame in 0..<(seconds * fps) {
            let image = renderer.image { context in
                UIColor(hue: CGFloat(frame % 60) / 60, saturation: 0.4, brightness: 0.9, alpha: 1)
                    .setFill()
                context.fill(CGRect(origin: .zero, size: size))
                for block in 0..<12 {
                    UIColor(
                        hue: CGFloat((block &* 7 &+ frame) % 100) / 100,
                        saturation: 0.8, brightness: 0.7, alpha: 1
                    ).setFill()
                    let offset = CGFloat((frame &* 6 &+ block &* 90) % Int(size.width))
                    context.fill(
                        CGRect(
                            x: offset, y: CGFloat(block) * size.height / 12,
                            width: size.width / 4, height: size.height / 12
                        )
                    )
                }
            }
            guard let buffer = pixelBuffer(from: image, size: size) else { continue }
            while !input.isReadyForMoreMediaData { await Task.yield() }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer
        )
        guard let buffer, let cgImage = image.cgImage else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return buffer
    }

    private func bytes(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Whatever the decision, the returned file must exist and be a playable
    /// video with a video track. Returning something unplayable would break
    /// sending entirely.
    func testResultIsAlwaysAPlayableVideo() async throws {
        let source = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertGreaterThan(bytes(source), 0, "precondition: a real source file")

        let result = await VideoCompressor.compressedForSending(source)
        defer { if result != source { try? FileManager.default.removeItem(at: result) } }

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        let tracks = try await AVURLAsset(url: result).loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty, "result has no video track")
    }

    /// A kept re-encode must be smaller than the original.
    ///
    /// Note what this can and cannot prove. Synthetically generated video does
    /// not compress like camera footage — flat blocks encode to almost nothing
    /// and land under the skip threshold, while per-pixel noise is
    /// incompressible so downscaling saves too little to keep. Both outcomes
    /// are the policy behaving correctly, so this asserts the invariant that
    /// holds either way rather than pretending to measure a saving. The
    /// keep/reject arithmetic itself is covered directly in
    /// `VideoCompressionPolicyTests`; a real saving needs real footage.
    func testAKeptReEncodeIsSmallerThanTheOriginal() async throws {
        let source = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }

        let originalBytes = bytes(source)
        let result = await VideoCompressor.compressedForSending(source)
        defer { if result != source { try? FileManager.default.removeItem(at: result) } }

        if result == source {
            // Declined — either below the threshold or not a big enough
            // saving. Both are correct; there is nothing further to assert.
            return
        }
        XCTAssertLessThan(
            bytes(result), originalBytes,
            "a kept re-encode must be smaller than the original"
        )
    }

    /// A clip already below the skip threshold must come back untouched, so a
    /// small send is not delayed by a pointless transcode.
    func testSmallClipIsReturnedUnchanged() async throws {
        let source = try await makeVideo(size: CGSize(width: 320, height: 240), seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }

        let result = await VideoCompressor.compressedForSending(source)
        XCTAssertEqual(result, source, "a small clip should be sent as-is")
    }

    /// A missing file must not crash or hang; the caller still gets a URL back.
    func testMissingSourceReturnsTheInput() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).mp4")
        let result = await VideoCompressor.compressedForSending(missing)
        XCTAssertEqual(result, missing)
    }
}

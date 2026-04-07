import AVFoundation
import Foundation
import UIKit
import SanchrShared

actor VoiceRecorder {

    func start() async throws {
        guard try await Self.requestPermission() else {
            throw VoiceRecorderError.permissionDenied
        }
        try activateSession()
        let url = Self.makeOutputURL()
        let r = try makeRecorder(url)
        guard r.record() else {
            throw VoiceRecorderError.sessionFailed("AVAudioRecorder.record() returned false")
        }
        self.recorder = r
        startMeteringLoop()
        installInterruptionObservers()
    }

    func stop() async throws -> Recording {
        guard let r = recorder else { throw VoiceRecorderError.fileMissing }
        let elapsed = r.currentTime
        r.stop()
        teardown()
        guard elapsed >= VoiceMessageState.minRecordingDuration else {
            _ = r.deleteRecording()
            throw VoiceRecorderError.recordingTooShort
        }
        let duration = Int(elapsed * 1000)
        let waveform = (try? await VoiceWaveformDecoder.decode(url: r.url, bins: 64)) ?? lastSamples
        return Recording(url: r.url, durationMs: duration, waveform: waveform)
    }

    func cancel() async {
        recorder?.stop()
        _ = recorder?.deleteRecording()
        teardown()
    }

    nonisolated var meterStream: AsyncStream<Float> { meterContinuation.stream }

    func startForTesting() async throws {
        let url = Self.makeOutputURL()
        let r = try makeRecorder(url)
        _ = r.record()
        self.recorder = r
    }

    static func makeOutputURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
    }

    init(
        makeRecorder: @escaping @Sendable (URL) throws -> AudioRecording = {
            try RealAudioRecorder(url: $0)
        }
    ) {
        self.makeRecorder = makeRecorder
    }

    private let makeRecorder: @Sendable (URL) throws -> AudioRecording
    private var recorder: AudioRecording?
    private var meterTask: Task<Void, Never>?
    private var lastSamples: [Float] = []
    private let meterContinuation = MeterContinuation()
    private var observers: [NSObjectProtocol] = []

    private static func requestPermission() async throws -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
    }

    private func startMeteringLoop() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let didTick = await self.tickMeter()
                if !didTick { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func tickMeter() -> Bool {
        guard let r = recorder else { return false }
        r.updateMeters()
        let normalized = Self.normalize(dB: r.averagePower)
        lastSamples.append(normalized)
        meterContinuation.yield(normalized)
        return true
    }

    private static func normalize(dB: Float) -> Float {
        let clamped = max(-60, min(0, dB))
        return (clamped + 60) / 60
    }

    private func installInterruptionObservers() {
        let nc = NotificationCenter.default
        let interruption = nc.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.handleInterruption() }
        }
        let background = nc.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.handleInterruption() }
        }
        let route = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw),
                reason == .oldDeviceUnavailable
            else { return }
            Task { await self?.handleInterruption() }
        }
        observers = [interruption, background, route]
    }

    private func handleInterruption() async {
        guard let r = recorder else { return }
        r.stop()
        let elapsed = r.currentTime
        let duration = Int(elapsed * 1000)
        let waveform = (try? await VoiceWaveformDecoder.decode(url: r.url, bins: 64)) ?? lastSamples
        let recording = Recording(url: r.url, durationMs: duration, waveform: waveform)
        teardown()
        interruptionContinuation.yield(recording)
    }

    nonisolated var interruptionStream: AsyncStream<Recording> { interruptionContinuation.stream }
    private let interruptionContinuation = RecordingContinuation()

    private func teardown() {
        meterTask?.cancel()
        meterTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

final class MeterContinuation: @unchecked Sendable {
    let stream: AsyncStream<Float>
    private let continuation: AsyncStream<Float>.Continuation
    init() {
        var c: AsyncStream<Float>.Continuation!
        self.stream = AsyncStream { c = $0 }
        self.continuation = c
    }
    func yield(_ s: Float) { continuation.yield(s) }
}

final class RecordingContinuation: @unchecked Sendable {
    let stream: AsyncStream<Recording>
    private let continuation: AsyncStream<Recording>.Continuation
    init() {
        var c: AsyncStream<Recording>.Continuation!
        self.stream = AsyncStream { c = $0 }
        self.continuation = c
    }
    func yield(_ r: Recording) { continuation.yield(r) }
}

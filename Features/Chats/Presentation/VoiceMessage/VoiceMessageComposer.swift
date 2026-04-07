import SwiftUI
import SanchrShared

struct VoiceMessageComposer: View {

    let playback: VoicePlaybackController
    let onActivate: () -> Void
    let onSend: (URL, Int, [Float]) -> Void

    @State private var state: VoiceMessageState = .idle
    @State private var elapsed: TimeInterval = 0
    @State private var liveSamples: [Float] = []
    @State private var showTooShortToast = false

    private let recorder = VoiceRecorder()
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch state {
            case .idle:
                micButton
            case .recording(let startedAt, let dragOffset, let locked):
                RecordingHUD(
                    elapsed: Date().timeIntervalSince(startedAt),
                    liveSamples: liveSamples,
                    dragOffset: dragOffset,
                    locked: locked,
                    onLockedStop: { Task { await stopRecording() } }
                )
                .gesture(dragGesture)
            case .preview(let rec):
                VoicePreviewBubble(
                    recording: rec,
                    playback: playback,
                    onDiscard: {
                        try? FileManager.default.removeItem(at: rec.url)
                        state = state.applyDiscard()
                    },
                    onSend: {
                        onSend(rec.url, rec.durationMs, rec.waveform)
                        state = state.applySend()
                    }
                )
            }
        }
        .onReceive(timer) { _ in
            if case .recording = state { elapsed += 0.1 }
        }
        .task {
            for await s in recorder.meterStream {
                liveSamples.append(s)
                if liveSamples.count > 240 { liveSamples.removeFirst(liveSamples.count - 240) }
            }
        }
        .task {
            for await rec in recorder.interruptionStream {
                state = state.applyInterruption(recording: rec)
            }
        }
    }

    private var micButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(SanchrExportColors.textSecondary)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .gesture(holdGesture)
    }

    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .onEnded { _ in
                Task { await startRecording() }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                state = state.applyDrag(g.translation)
                if case .idle = state {
                    Task { await recorder.cancel() }
                }
            }
            .onEnded { _ in
                Task { await releaseRecording() }
            }
    }

    private func startRecording() async {
        onActivate()
        do {
            try await recorder.start()
            state = state.applyPress(at: Date())
            liveSamples = []
            elapsed = 0
        } catch VoiceRecorderError.permissionDenied {
            state = .idle
        } catch {
            state = .idle
        }
    }

    private func releaseRecording() async {
        guard case .recording(_, _, let locked) = state, !locked else { return }
        await stopRecording()
    }

    private func stopRecording() async {
        do {
            let rec = try await recorder.stop()
            let outcome = state.applyRelease(now: Date(), recording: rec)
            state = outcome.state
            if outcome.shouldShowTooShortToast {
                showTooShortToast = true
                try? FileManager.default.removeItem(at: rec.url)
            }
        } catch VoiceRecorderError.recordingTooShort {
            state = .idle
            showTooShortToast = true
        } catch {
            state = .idle
        }
    }
}

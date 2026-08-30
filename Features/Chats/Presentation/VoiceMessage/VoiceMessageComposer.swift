import SwiftUI
import UIKit
import SanchrShared

struct VoiceMessageComposer: View {

    let playback: VoicePlaybackController
    let onActivate: () -> Void
    let onSend: (URL, Int, [Float]) -> Void

    @State private var state: VoiceMessageState = .idle
    @State private var elapsed: TimeInterval = 0
    @State private var liveSamples: [Float] = []
    @State private var showTooShortToast = false
    /// Set when recording could not start. Holding the mic used to do nothing
    /// at all in that case — every error, including a denied microphone
    /// permission, was swallowed into `.idle` with nothing on screen.
    @State private var startFailure: StartFailure?

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
        .alert(item: $startFailure) { failure in
            switch failure {
            case .microphoneDenied:
                return Alert(
                    title: Text(failure.title),
                    message: Text(failure.message),
                    // Deep-linking to the app's own page is the only route
                    // iOS offers; there is no in-app way back from a denial.
                    primaryButton: .default(Text("Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    },
                    secondaryButton: .cancel(Text("Not Now"))
                )
            case .other:
                return Alert(
                    title: Text(failure.title),
                    message: Text(failure.message),
                    dismissButton: .default(Text("OK"))
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
        Button(action: handleMicButtonTap) {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(SanchrExportColors.textSecondary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(holdGesture)
        .accessibilityLabel("Voice message")
        .accessibilityHint("Press and hold to record a voice message.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Start recording") {
            Task { await startRecording() }
        }
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

    /// Why recording could not start, in terms the user can act on.
    enum StartFailure: Identifiable {
        case microphoneDenied
        case other(String)

        var id: String {
            switch self {
            case .microphoneDenied: return "denied"
            case .other(let message): return message
            }
        }

        var title: String {
            switch self {
            case .microphoneDenied: return "Microphone access is off"
            case .other: return "Couldn't start recording"
            }
        }

        var message: String {
            switch self {
            case .microphoneDenied:
                return "Sanchr needs the microphone to record a voice message. "
                    + "You can turn it on in Settings."
            case .other(let message):
                return message
            }
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
            startFailure = .microphoneDenied
        } catch {
            // Anything else — a busy session, a file that could not be created.
            // Previously indistinguishable from success-then-nothing.
            state = .idle
            startFailure = .other(error.localizedDescription)
        }
    }

    private func handleMicButtonTap() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        Task { await startRecording() }
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

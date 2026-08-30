import SwiftUI
import UIKit
import SanchrShared

struct VoiceMessageComposer: View {

    let playback: VoicePlaybackController
    let onActivate: () -> Void
    let onSend: (URL, Int, [Float]) -> Void
    /// True while recording or reviewing.
    ///
    /// The composer lives in the input bar's trailing button slot, sized for a
    /// mic. The recording bar and the preview are full-width rows, and without
    /// telling anyone they were squeezed into that slot next to the text
    /// field. The bar hides the rest of the row while this is set.
    @Binding var isCapturing: Bool

    @State private var state: VoiceMessageState = .idle
    @State private var elapsed: TimeInterval = 0
    @State private var liveSamples: [Float] = []
    @State private var showTooShortToast = false
    /// Set when recording could not start. Holding the mic used to do nothing
    /// at all in that case — every error, including a denied microphone
    /// permission, was swallowed into `.idle` with nothing on screen.
    @State private var startFailure: StartFailure?

    private let recorder = VoiceRecorder()

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
                    onStop: { Task { await stopLockedRecording() } },
                    onCancel: { Task { await cancelRecording() } }
                )
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
        // On the container, not on the HUD.
        //
        // The gesture used to live on the HUD — which only exists once
        // recording has started, by which time the finger is already down. A
        // recogniser attached to a view that appears mid-touch never sees that
        // touch, so sliding to cancel and sliding to lock did nothing, and the
        // release that should have ended the recording was never delivered
        // either. The container is present from before the press.
        .frame(maxWidth: isCapturing ? .infinity : nil)
        .simultaneousGesture(dragGesture)
        .onChange(of: state) { _, new in
            let capturing: Bool
            switch new {
            case .idle: capturing = false
            case .recording, .preview: capturing = true
            }
            guard capturing != isCapturing else { return }
            withAnimation(.easeInOut(duration: 0.2)) { isCapturing = capturing }
        }
        .overlay(alignment: .top) { tooShortToast }
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
        // Runs only while recording. As a stored `.autoconnect()` publisher this
        // fired ten times a second for the entire life of the chat screen, for
        // a value that is only read during a recording.
        //
        // The tick is what redraws the HUD: `elapsed` is never displayed —
        // `RecordingHUD` computes the time from `startedAt` — so its only job
        // is to invalidate the body. That was previously implicit enough that
        // deleting the "unused" variable would have silently frozen the timer.
        .task(id: isRecording) {
            guard isRecording else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                elapsed += 0.1
            }
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

    private var isRecording: Bool {
        if case .recording = state { return true }
        return false
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
                // Live on the container, so it sees touches that have nothing
                // to do with recording — the preview's buttons, a stray tap on
                // the mic. Only a recording responds.
                guard isRecording else { return }
                state = state.applyDrag(g.translation)
                if case .idle = state {
                    Task { await recorder.cancel() }
                }
            }
            .onEnded { _ in
                guard isRecording else { return }
                Task { await releaseRecording() }
            }
    }

    /// Shown when a recording was too short to send.
    ///
    /// The flag behind this was set in two places and read in none, so letting
    /// go too quickly deleted the recording and said nothing at all — the same
    /// silence as a failure.
    @ViewBuilder
    private var tooShortToast: some View {
        if showTooShortToast {
            Text("Hold to record")
                .font(SanchrTypography.captionSmall)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.78), in: Capsule())
                .fixedSize()
                .offset(y: -42)
                .transition(.opacity)
                .accessibilityHidden(true)
                .task {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    withAnimation { showTooShortToast = false }
                }
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
            // Started from the VoiceOver action there is no finger holding
            // anything, so the only operable state is the hands-free one —
            // which is also the only one with buttons to stop or delete.
            state = state.applyPress(
                at: Date(),
                locked: UIAccessibility.isVoiceOverRunning
            )
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

    /// The finger came up. Ignored once locked — the recording is meant to
    /// carry on without it.
    private func releaseRecording() async {
        guard case .recording(_, _, let locked) = state, !locked else { return }
        do {
            let rec = try await recorder.stop()
            let outcome = state.applyRelease(now: Date(), recording: rec)
            state = outcome.state
            if outcome.shouldShowTooShortToast {
                withAnimation { showTooShortToast = true }
                try? FileManager.default.removeItem(at: rec.url)
            }
        } catch VoiceRecorderError.recordingTooShort {
            state = .idle
            withAnimation { showTooShortToast = true }
        } catch {
            state = .idle
        }
    }

    /// The stop button on a locked recording.
    ///
    /// This used to call the same path as a finger lifting, which returns the
    /// state *unchanged* when locked — deliberately, so that letting go does
    /// not end a hands-free recording. So the recorder stopped and tore down
    /// its session while the HUD stayed on screen, and the recording was lost.
    /// `applyLockedStop` existed for this and was never called.
    private func stopLockedRecording() async {
        do {
            let rec = try await recorder.stop()
            state = state.applyLockedStop(recording: rec)
        } catch VoiceRecorderError.recordingTooShort {
            state = .idle
            withAnimation { showTooShortToast = true }
        } catch {
            state = .idle
        }
    }

    /// Discard an in-progress recording outright.
    private func cancelRecording() async {
        await recorder.cancel()
        state = state.applyCancel()
    }
}

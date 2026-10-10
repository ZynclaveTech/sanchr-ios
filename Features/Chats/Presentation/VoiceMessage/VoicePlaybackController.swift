import Foundation
import AVFoundation
import Observation
import SanchrShared

@Observable
final class VoicePlaybackController: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {

    private(set) var currentlyPlayingMessageId: String?
    /// Whether audio is actually running, as distinct from which message is
    /// loaded. `pause()` keeps the message current — that is what preserves
    /// the playback position — so a view asking only "is this the current
    /// message" showed a pause button on a paused clip.
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    func play(url: URL, messageId: String) throws {
        if currentlyPlayingMessageId != messageId {
            stop()
        }
        activateSession()
        if player == nil {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            self.player = p
        }
        player?.play()
        currentlyPlayingMessageId = messageId
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        progressTimer?.invalidate()
    }

    func stop() {
        player?.stop()
        player = nil
        currentlyPlayingMessageId = nil
        isPlaying = false
        progress = 0
        progressTimer?.invalidate()
        progressTimer = nil
        deactivateSession()
    }

    /// Playback never configured the audio session at all.
    ///
    /// Without a category of its own the app falls under `.soloAmbient`, which
    /// is silenced by the Ring/Silent switch: a voice note played cold was
    /// mute with no indication why. Played right after recording it inherited
    /// `.playAndRecord` and worked, which is why this survived.
    ///
    /// `.playback` is the category for media the user asked to hear, and it
    /// plays with the switch on, as every messenger's voice notes do.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            // Not fatal: the clip may still play under whatever category is
            // active. Worth knowing about, though, because it is the reason a
            // silent-switch mute would come back.
            SanchrLogger.chat.error("Voice playback session setup failed: \(error.localizedDescription)")
        }
    }

    /// Hands the session back so other apps' audio resumes. Nothing did this,
    /// so music paused for a voice note stayed paused.
    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    deinit {
        // `pause()` invalidates the timer but leaves it non-nil, and there was
        // no deinit: releasing the controller mid-playback left a repeating
        // main-run-loop timer firing forever.
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func seek(to fraction: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(p.duration, p.duration * fraction))
        progress = fraction
    }

    private func startTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.player, p.duration > 0 else { return }
            self.progress = p.currentTime / p.duration
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }
}

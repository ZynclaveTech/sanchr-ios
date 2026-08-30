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

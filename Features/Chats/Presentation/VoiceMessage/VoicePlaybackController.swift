import Foundation
import AVFoundation
import Observation
import SanchrShared

@Observable
final class VoicePlaybackController: NSObject, AVAudioPlayerDelegate {

    private(set) var currentlyPlayingMessageId: String?
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
        startTimer()
    }

    func pause() {
        player?.pause()
        progressTimer?.invalidate()
    }

    func stop() {
        player?.stop()
        player = nil
        currentlyPlayingMessageId = nil
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

import AVFoundation
import SanchrShared

/// Audio session handling for video played in the gallery.
///
/// Nothing in the app ever asked for a playback category, so the session sat on
/// its default — which obeys the ring/silent switch. A video opened on a phone
/// set to silent therefore played with no sound at all, and there was no
/// on-screen clue why. Every messenger sets `.playback` for this reason: a
/// video someone chose to open is not incidental audio.
///
/// It also cleans up after voice notes. Recording leaves the session on
/// `.playAndRecord` with `defaultToSpeaker`, and nothing put it back, so a
/// video opened afterwards inherited a routing setup meant for a microphone.
enum GalleryAudioSession {

    /// Whether a call currently owns the session.
    ///
    /// Calls configure `.playAndRecord` with `.voiceChat`, and voice notes use
    /// the same category with the default mode — so the mode, not the
    /// category, is what tells them apart. Taking the session from a live call
    /// would cut its audio, which is far worse than a silent video.
    private static var callInProgress: Bool {
        AVAudioSession.sharedInstance().mode == .voiceChat
    }

    /// Makes gallery video audible, including on a phone switched to silent.
    static func activateForPlayback() {
        guard !callInProgress else {
            SanchrLogger.media.info("Gallery audio: call in progress, leaving the session alone")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Best effort. A video that plays silently is a poor experience;
            // one that refuses to open because of an audio route is worse.
            SanchrLogger.media.warning(
                "Gallery audio: could not activate playback session: \(error.localizedDescription)"
            )
        }
    }

    /// Hands the session back when the viewer closes.
    ///
    /// `notifyOthersOnDeactivation` is what lets whatever was playing before —
    /// music, a podcast — pick up again instead of staying stopped.
    static func deactivate() {
        guard !callInProgress else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        } catch {
            SanchrLogger.media.warning(
                "Gallery audio: could not release the session: \(error.localizedDescription)"
            )
        }
    }
}

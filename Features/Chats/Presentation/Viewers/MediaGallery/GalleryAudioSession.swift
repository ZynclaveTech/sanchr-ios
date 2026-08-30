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

    /// Makes gallery video audible, including on a phone switched to silent.
    ///
    /// - Parameter callInProgress: whether a call currently owns the session.
    ///   Passed in rather than inferred: the obvious-looking test — is the
    ///   session's mode `.voiceChat` — is wrong, because category and mode are
    ///   sticky. CallKit deactivating the session does not clear them, and
    ///   nothing in the call teardown resets them either, so after the first
    ///   call of a session the mode reads `.voiceChat` forever. Inferring from
    ///   it meant every video opened after any call played silently.
    static func activateForPlayback(callInProgress: Bool) {
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
    static func deactivate(callInProgress: Bool) {
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

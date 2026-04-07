import SwiftUI
import AVKit

/// `AVPlayerViewController` wrapper. Gives the gallery native scrub bar,
/// skip-15s, AirPlay, PiP, speed, and subtitle support for free.
///
/// The player is created when the page first becomes active and paused
/// automatically when the `isActive` binding flips false (i.e. the pager
/// scrolled away from this page). PiP is the only state that survives
/// dismissal — that's handled by `AVFoundation` itself, nothing to wire
/// here.
struct GalleryVideoView: UIViewControllerRepresentable {
    let url: URL
    @Binding var isActive: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.canStartPictureInPictureAutomaticallyFromInline = false
        vc.modalPresentationStyle = .overFullScreen
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if !isActive {
            vc.player?.pause()
        }
    }

    static func dismantleUIViewController(
        _ vc: AVPlayerViewController,
        coordinator: ()
    ) {
        vc.player?.pause()
        vc.player = nil
    }
}

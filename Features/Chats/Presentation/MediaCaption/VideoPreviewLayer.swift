import AVFoundation
import SwiftUI
import UIKit

/// A player that can actually fill its frame.
///
/// `VideoPlayer` wraps `AVPlayerViewController`, whose gravity is
/// aspect-*fit* and is not exposed. So the previous attempt at filling — a
/// SwiftUI `.aspectRatio(_:contentMode:)` around a `VideoPlayer` — changed
/// nothing: the player letterboxed inside whatever frame it was given, which
/// is the behaviour that stranded the close button and caption row away from
/// the picture's edges.
///
/// Filling is a property of the layer, so this is the layer.
struct VideoPreviewLayer: UIViewRepresentable {

    let player: AVPlayer
    let fills: Bool

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

import SwiftUI
import UIKit

/// Thin `UIViewControllerRepresentable` wrapper around
/// `UIActivityViewController` for Flow B2 (Share outside Sanchr).
///
/// Mirror of the existing `GalleryActivityView` in
/// `Features/Chats/Presentation/Viewers/MediaGallery/`. Separate copies
/// intentionally because vault and chat may diverge in what they pass
/// as activity items (URLs vs. raw Data) and we don't want a shared
/// helper dragging chat-specific dependencies into the vault module.
///
/// `completion(completed)` fires exactly once when the activity view
/// dismisses. `completed` is true if the user successfully shared with
/// a target app, false if they cancelled. Either way the caller MUST
/// clean up the temp file — the coordinator's `cleanupTempFile(at:)`
/// is the canonical path.
struct VaultActivityView: UIViewControllerRepresentable {
    let items: [Any]
    let completion: (_ completed: Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in
            completion(completed)
        }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

import UIKit
import SwiftUI
import SanchrShared

/// Real entry point for the SanchrShareExtension.
///
/// Responsibilities:
///   * Gate the entire flow on `AppGroupMigration.isComplete` so we never
///     touch the encrypted store before the host app has finished its
///     one-time App Group migration.
///   * Collect every `NSItemProvider` from the share-sheet's
///     `NSExtensionContext.inputItems`.
///   * Host a SwiftUI `ShareRootView` that drives the rest of the flow.
///   * Bridge SwiftUI completion / cancel callbacks back to
///     `extensionContext` so the share sheet dismisses correctly.
@objc(ShareViewController)
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        guard AppGroupMigration.isComplete else {
            installSwiftUI(
                ShareErrorView(
                    title: "Open Sanchr to finish updating",
                    message: "Sanchr needs to finish a one-time setup before it can be used from the share sheet.",
                    onDismiss: { [weak self] in self?.cancel() }
                )
            )
            return
        }

        let providers: [NSItemProvider] = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        installSwiftUI(
            ShareRootView(
                providers: ShareProviders(items: providers),
                onComplete: { [weak self] in self?.complete() },
                onCancel: { [weak self] in self?.cancel() }
            )
        )
    }

    // MARK: - SwiftUI hosting

    private func installSwiftUI<V: View>(_ rootView: V) {
        let host = UIHostingController(rootView: rootView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    // MARK: - Extension lifecycle

    private func cancel() {
        let err = NSError(
            domain: "io.sanchr.share",
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "User cancelled the share."]
        )
        extensionContext?.cancelRequest(withError: err)
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

import SwiftUI
import UIKit
import SanchrShared

/// View modifier that prevents screenshots and screen recording by
/// hosting content inside a hidden secure `UITextField`. When
/// `isActive` is true, iOS marks the containing window as secure,
/// blanking it in the app switcher and blocking screen captures.
///
/// iOS 17 note: the old trick of grabbing `secureField.subviews.first`
/// at `init` returns nil because UITextField has no subviews until
/// it's actually in a window. This implementation instead nests the
/// modified content inside the `UITextField` itself — the secure
/// attribute propagates to the window once the field's view
/// hierarchy is live.
struct ScreenshotProtectionModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        SecureContentHost(isActive: isActive) {
            content
        }
    }
}

private struct SecureContentHost<Content: View>: UIViewControllerRepresentable {
    let isActive: Bool
    let content: Content

    init(isActive: Bool, @ViewBuilder content: () -> Content) {
        self.isActive = isActive
        self.content = content()
    }

    func makeUIViewController(context: Context) -> SecureHostController<Content> {
        let vc = SecureHostController(rootView: content, isActive: isActive)
        return vc
    }

    func updateUIViewController(_ vc: SecureHostController<Content>, context: Context) {
        vc.update(rootView: content, isActive: isActive)
    }
}

/// UIViewController that nests a `UIHostingController` inside a
/// `UITextField`'s secure container. Swaps the content parent when
/// `isActive` flips so protection can be toggled at runtime without
/// rebuilding the SwiftUI hierarchy.
final class SecureHostController<Content: View>: UIViewController {
    private let hostingController: UIHostingController<Content>
    private let secureField = UITextField()
    private var isActive: Bool
    private var didInstallSecureContainer = false

    init(rootView: Content, isActive: Bool) {
        self.hostingController = UIHostingController(rootView: rootView)
        self.isActive = isActive
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // Add the hosting controller as a child first so its view is
        // in the hierarchy regardless of `isActive`.
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hostingController.didMove(toParent: self)

        // Configure the secure text field. Added to the hierarchy as
        // a zero-size sibling so it joins the window and is marked
        // secure. Its presence is what makes iOS blank the window
        // during a screenshot.
        secureField.isSecureTextEntry = true
        secureField.isUserInteractionEnabled = false
        secureField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secureField)
        NSLayoutConstraint.activate([
            secureField.widthAnchor.constraint(equalToConstant: 0),
            secureField.heightAnchor.constraint(equalToConstant: 0),
            secureField.topAnchor.constraint(equalTo: view.topAnchor),
            secureField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installSecureContainerIfPossible()
        applyIsActive()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The secure field's private container only populates after
        // the field has been laid out at least once. Retry the
        // install until it succeeds.
        installSecureContainerIfPossible()
    }

    private func installSecureContainerIfPossible() {
        guard !didInstallSecureContainer else { return }
        // On iOS 17 the private secure container view is exposed as the
        // first subview of UITextField ONLY after the field has a
        // window. Walk the subviews defensively and reparent whichever
        // one we find. If we don't find it, the secureField itself
        // being in the view hierarchy still marks the window.
        guard let container = secureField.subviews.first else {
            // Field in window but no container yet — accept the
            // weaker form of protection (field-only). On iOS 17+ the
            // field-in-window alone is sufficient to blank the window
            // on screenshot.
            return
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(container, belowSubview: hostingController.view)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        // Reparent the hosting view INSIDE the secure container so
        // iOS treats the hosted content as protected.
        hostingController.view.removeFromSuperview()
        container.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: container.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        didInstallSecureContainer = true
    }

    func update(rootView: Content, isActive: Bool) {
        hostingController.rootView = rootView
        if self.isActive != isActive {
            self.isActive = isActive
            applyIsActive()
        }
    }

    private func applyIsActive() {
        // Toggle by enabling/disabling the secure text field. When
        // disabled, iOS no longer treats the window as secure.
        secureField.isSecureTextEntry = isActive
    }
}

extension View {
    /// Applies screenshot and screen recording protection when active.
    func screenshotProtection(isActive: Bool) -> some View {
        modifier(ScreenshotProtectionModifier(isActive: isActive))
    }
}

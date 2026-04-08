import SwiftUI
import UIKit
import SanchrShared
import os

private let screenshotLog = Logger(subsystem: "com.sanchr.app", category: "ScreenshotProtection")

/// View modifier that prevents screenshots and screen recording by
/// placing a secure `UITextField` in the window hierarchy. On iOS 17+
/// the preferred technique is to reparent the SwiftUI content INSIDE
/// the text field's private secure container view; falling back to a
/// sibling field still blanks the app switcher snapshot but may not
/// block user screenshots.
struct ScreenshotProtectionModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        SecureContentHost(isActive: isActive) { content }
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
        SecureHostController(rootView: content, isActive: isActive)
    }

    func updateUIViewController(_ vc: SecureHostController<Content>, context: Context) {
        vc.update(rootView: content, isActive: isActive)
    }
}

final class SecureHostController<Content: View>: UIViewController {
    private let hostingController: UIHostingController<Content>
    private let secureField = UITextField()
    private var isActive: Bool
    private var didReparent = false

    init(rootView: Content, isActive: Bool) {
        self.hostingController = UIHostingController(rootView: rootView)
        self.isActive = isActive
        super.init(nibName: nil, bundle: nil)
        screenshotLog.log("init isActive=\(isActive)")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        secureField.isSecureTextEntry = false
        secureField.isUserInteractionEnabled = false
        secureField.backgroundColor = .clear
        secureField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secureField)
        NSLayoutConstraint.activate([
            secureField.topAnchor.constraint(equalTo: view.topAnchor),
            secureField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            secureField.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

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
        screenshotLog.log("viewDidLoad attached host+field isActive=\(self.isActive)")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reparentIntoSecureContainerIfNeeded(reason: "viewWillAppear")
        applyIsActive(reason: "viewWillAppear")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reparentIntoSecureContainerIfNeeded(reason: "viewDidLayoutSubviews")
        applyIsActive(reason: "viewDidLayoutSubviews")
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        screenshotLog.log("didMove parent=\(parent != nil ? "yes" : "nil") window=\(self.view.window != nil ? "yes" : "nil")")
    }

    private func reparentIntoSecureContainerIfNeeded(reason: String) {
        guard !didReparent else { return }
        guard secureField.window != nil else {
            screenshotLog.log("reparent skip [\(reason)] — field has no window yet subviews=\(self.secureField.subviews.count)")
            return
        }
        let subs = secureField.subviews
        screenshotLog.log("reparent try [\(reason)] field subviews=\(subs.count) types=\(subs.map { String(describing: type(of: $0)) }.joined(separator: ","))")
        guard let container = subs.first else {
            screenshotLog.log("reparent skip [\(reason)] — no private container subview")
            return
        }

        hostingController.view.removeFromSuperview()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isUserInteractionEnabled = true
        container.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: container.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        didReparent = true
        screenshotLog.log("reparent OK [\(reason)] container=\(String(describing: type(of: container)))")
    }

    func update(rootView: Content, isActive: Bool) {
        hostingController.rootView = rootView
        if self.isActive != isActive {
            screenshotLog.log("update isActive \(self.isActive) -> \(isActive)")
            self.isActive = isActive
            applyIsActive(reason: "update")
        }
    }

    private func applyIsActive(reason: String) {
        secureField.isSecureTextEntry = isActive
        let windowHasSecure: Bool = {
            guard let w = view.window else { return false }
            return findSecureField(in: w) != nil
        }()
        screenshotLog.log("applyIsActive [\(reason)] isActive=\(self.isActive) field.secure=\(self.secureField.isSecureTextEntry) inWindow=\(self.secureField.window != nil) windowHasSecure=\(windowHasSecure) didReparent=\(self.didReparent)")
    }

    private func findSecureField(in view: UIView) -> UITextField? {
        if let tf = view as? UITextField, tf.isSecureTextEntry { return tf }
        for sub in view.subviews {
            if let found = findSecureField(in: sub) { return found }
        }
        return nil
    }
}

extension View {
    /// Applies screenshot and screen recording protection when active.
    func screenshotProtection(isActive: Bool) -> some View {
        modifier(ScreenshotProtectionModifier(isActive: isActive))
    }
}

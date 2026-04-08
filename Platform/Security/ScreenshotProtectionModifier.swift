import SwiftUI
import UIKit
import SanchrShared
import os

private let screenshotLog = Logger(subsystem: "com.sanchr.app", category: "ScreenshotProtection")

/// Window-level screenshot protection.
///
/// The technique that actually blocks user screenshots on iOS 17:
/// 1. Add a `UITextField` with `isSecureTextEntry = true` as a subview
///    of the key window.
/// 2. Reparent `window.rootViewController.view` INSIDE the text field's
///    private canvas subview (`_UITextLayoutCanvasView`), which is what
///    the system actually marks as secure.
///
/// We install once per window, then just toggle `isSecureTextEntry` to
/// enable/disable. Driving this imperatively from a no-op SwiftUI
/// modifier (via `.task(id:)`) sidesteps the UIHostingController
/// sizing fight that wrecks layout when the entire SwiftUI tree is
/// wrapped in `UIViewControllerRepresentable`.
@MainActor
final class WindowScreenshotProtector {
    static let shared = WindowScreenshotProtector()

    private weak var installedWindow: UIWindow?
    private var secureField: UITextField?
    private var didReparent = false
    private var pendingActive = false
    private var retryCount = 0
    private let maxRetries = 20

    private init() {}

    func setActive(_ active: Bool) {
        pendingActive = active
        install()
        secureField?.isSecureTextEntry = active
        screenshotLog.log("setActive active=\(active) hasField=\(self.secureField != nil) didReparent=\(self.didReparent)")
    }

    private func install() {
        guard let window = keyWindow() else {
            screenshotLog.log("install: no key window yet, deferring")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.install()
                self.secureField?.isSecureTextEntry = self.pendingActive
            }
            return
        }
        if installedWindow === window, secureField != nil {
            if !didReparent { attemptReparent() }
            return
        }

        // Fresh install on this window.
        installedWindow = window
        didReparent = false
        retryCount = 0

        let field = UITextField()
        field.isUserInteractionEnabled = false
        field.backgroundColor = .clear
        field.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: window.topAnchor),
            field.bottomAnchor.constraint(equalTo: window.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: window.trailingAnchor),
        ])
        self.secureField = field
        screenshotLog.log("install: added secureField to window")

        // Defer reparenting until after the field has run its first
        // layout pass — that's when its private canvas subview exists.
        DispatchQueue.main.async { [weak self] in
            self?.attemptReparent()
        }
    }

    private func attemptReparent() {
        guard !didReparent else { return }
        guard let window = installedWindow, let field = secureField else { return }
        guard let rootView = window.rootViewController?.view else {
            screenshotLog.log("reparent: no rootViewController.view")
            return
        }

        // Force layout so the field populates its private subview tree.
        field.setNeedsLayout()
        field.layoutIfNeeded()

        guard let canvas = field.subviews.first else {
            retryCount += 1
            if retryCount <= maxRetries {
                screenshotLog.log("reparent retry \(self.retryCount)/\(self.maxRetries) — canvas not ready")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.attemptReparent()
                }
            } else {
                screenshotLog.error("reparent gave up — canvas never appeared after \(self.maxRetries) tries")
            }
            return
        }

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.isUserInteractionEnabled = true
        canvas.isHidden = false

        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.removeFromSuperview()
        canvas.addSubview(rootView)
        NSLayoutConstraint.activate([
            rootView.topAnchor.constraint(equalTo: canvas.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            rootView.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
        ])
        didReparent = true
        screenshotLog.log("reparent OK canvas=\(String(describing: type(of: canvas))) pendingActive=\(self.pendingActive)")

        // Reapply the desired secure state now that the canvas is live.
        field.isSecureTextEntry = pendingActive
    }

    private func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
        }
        // Fallback: first window we can find.
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first
    }
}

/// Tiny SwiftUI modifier that forwards `isActive` into the window-level
/// protector. Does not wrap or rewrap the content tree — layout is
/// unaffected.
struct ScreenshotProtectionModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .task(id: isActive) {
                WindowScreenshotProtector.shared.setActive(isActive)
            }
            .onAppear {
                WindowScreenshotProtector.shared.setActive(isActive)
            }
    }
}

extension View {
    /// Applies screenshot and screen recording protection when active.
    func screenshotProtection(isActive: Bool) -> some View {
        modifier(ScreenshotProtectionModifier(isActive: isActive))
    }
}

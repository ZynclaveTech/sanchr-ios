import Foundation
import UIKit

/// Centralizes UIKit live-capture observation for app-level privacy
/// handling. Still screenshots remain detectable only after the fact;
/// `isScreenCaptureActive` tracks screen recording, QuickTime mirroring,
/// AirPlay, and similar live capture paths.
@Observable
@MainActor
final class ScreenCaptureMonitor {
    private(set) var isScreenCaptureActive: Bool

    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let capturedDidChangeNotification: Notification.Name
    @ObservationIgnored private let currentCaptureState: @MainActor @Sendable () -> Bool
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        capturedDidChangeNotification: Notification.Name = UIScreen.capturedDidChangeNotification,
        currentCaptureState: @escaping @MainActor @Sendable () -> Bool = { UIScreen.main.isCaptured }
    ) {
        self.notificationCenter = notificationCenter
        self.capturedDidChangeNotification = capturedDidChangeNotification
        self.currentCaptureState = currentCaptureState
        self.isScreenCaptureActive = currentCaptureState()
        observer = notificationCenter.addObserver(
            forName: capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        isScreenCaptureActive = currentCaptureState()
    }
}

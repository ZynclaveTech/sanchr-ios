import XCTest

@testable import Sanchr

@MainActor
final class ScreenCaptureMonitorTests: XCTestCase {

    func test_initializesWithCurrentCaptureState() {
        let notificationCenter = NotificationCenter()
        let box = CaptureStateBox(isCaptured: true)

        let monitor = ScreenCaptureMonitor(
            notificationCenter: notificationCenter,
            capturedDidChangeNotification: .testScreenCaptureDidChange,
            currentCaptureState: { box.isCaptured }
        )

        XCTAssertTrue(monitor.isScreenCaptureActive)
    }

    func test_refreshesWhenCaptureNotificationPosts() async {
        let notificationCenter = NotificationCenter()
        let box = CaptureStateBox(isCaptured: false)
        let monitor = ScreenCaptureMonitor(
            notificationCenter: notificationCenter,
            capturedDidChangeNotification: .testScreenCaptureDidChange,
            currentCaptureState: { box.isCaptured }
        )

        box.isCaptured = true
        notificationCenter.post(name: .testScreenCaptureDidChange, object: nil)
        await Task.yield()

        XCTAssertTrue(monitor.isScreenCaptureActive)
    }

    func test_presentation_redactsOnlyForActiveLiveCapture() {
        let disabled = ScreenshotProtectionPresentation(
            isProtectionEnabled: false,
            isScreenCaptureActive: true
        )
        XCTAssertFalse(disabled.isSecureMarkerActive)
        XCTAssertFalse(disabled.shouldRedactForLiveCapture)

        let idle = ScreenshotProtectionPresentation(
            isProtectionEnabled: true,
            isScreenCaptureActive: false
        )
        XCTAssertTrue(idle.isSecureMarkerActive)
        XCTAssertFalse(idle.shouldRedactForLiveCapture)

        let active = ScreenshotProtectionPresentation(
            isProtectionEnabled: true,
            isScreenCaptureActive: true
        )
        XCTAssertTrue(active.isSecureMarkerActive)
        XCTAssertTrue(active.shouldRedactForLiveCapture)
    }
}

private final class CaptureStateBox {
    var isCaptured: Bool

    init(isCaptured: Bool) {
        self.isCaptured = isCaptured
    }
}

private extension Notification.Name {
    static let testScreenCaptureDidChange = Notification.Name("test.screenCaptureDidChange")
}

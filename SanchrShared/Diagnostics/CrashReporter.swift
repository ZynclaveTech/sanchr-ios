import Foundation
import Sentry

/// Crash reporting to our own Sentry, off unless the user turns it on.
///
/// Sentry, self-hosted, rather than Crashlytics — because of who receives
/// the report. Crashlytics depends on Firebase Installations, which mints a
/// per-install identifier and sends it to Google with every event;
/// declining to set a user id does not prevent that. Signal takes no
/// automatic crash reports at all, and WhatsApp reports to Meta's own
/// infrastructure. Both reject the shape Crashlytics has. Reporting to
/// infrastructure we run keeps the operational value without handing a
/// third party a stable identifier for every install.
///
/// Inert when no DSN is configured, which is the default, so a fork or a
/// local build reports nowhere.
public final class CrashReporter: @unchecked Sendable {
    public static let shared = CrashReporter()

    /// Where reports go. Read from the app's Info.plist so it is injected at
    /// build time rather than committed: a DSN is embedded in every client
    /// that uses it and so is not a secret in the way a token is, but it
    /// does name our infrastructure.
    private static var configuredDSN: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "SanchrSentryDSN") as? String
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    private let defaults: UserDefaults
    private var started = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Starts the SDK if there is a DSN and the user has consented.
    ///
    /// Call as early in launch as possible, so a crash during startup is
    /// still captured for someone who opted in. Nothing starts without
    /// consent, so a user who never opts in has no client at all.
    public func start() {
        guard CrashReportingConsent.isEnabled(defaults: defaults) else { return }
        startIfPossible()
    }

    /// Records the choice and applies it immediately, so revoking consent
    /// stops collection now rather than at next launch.
    public func setEnabled(_ enabled: Bool) {
        CrashReportingConsent.setEnabled(enabled, defaults: defaults)
        if enabled {
            startIfPossible()
        } else if started {
            // close() rather than a flag: it stops the transport and drops
            // what is queued, so consent withdrawn means nothing already
            // captured still reaches the server.
            SentrySDK.close()
            started = false
        }
    }

    /// Records a handled error worth knowing about.
    ///
    /// The error's own text never leaves the device: a caught error here can
    /// carry a phone number or a message body, so only a type-and-domain
    /// summary is attached.
    public func recordHandled(_ error: Error, context: String? = nil) {
        guard started else { return }
        if let context {
            SentrySDK.addBreadcrumb(breadcrumb(CrashReportRedaction.redact(context)))
        }
        SentrySDK.addBreadcrumb(breadcrumb(CrashReportRedaction.summarise(error)))
        SentrySDK.capture(error: error)
    }

    private func startIfPossible() {
        guard !started, let dsn = Self.configuredDSN else { return }
        SentrySDK.start { options in
            options.dsn = dsn

            // Stops the client attaching the device's IP address and
            // similar. The server sees the IP regardless, so it must also be
            // set to discard it; this is the half we control from here.
            options.sendDefaultPii = false

            // A screenshot or view hierarchy of a messenger is message
            // content. Never.
            options.attachScreenshot = false
            options.attachViewHierarchy = false

            // Automatic breadcrumbs trace UI and network activity, which
            // here means conversation ids and request URLs. Only the ones
            // added deliberately, already redacted.
            options.enableAutoBreadcrumbTracking = false
            options.enableAutoSessionTracking = false
            options.enableNetworkTracking = false

            // Last line of defence. An error message is free text that could
            // hold anything, so it is redacted on the way out even though
            // recordHandled already summarises.
            options.beforeSend = { event in
                if let message = event.message {
                    event.message = SentryMessage(formatted: CrashReportRedaction.redact(message.formatted))
                }
                // Sentry otherwise infers a user from the install; dropping
                // it is what stops per-person crash counting.
                event.user = nil
                return event
            }
        }
        started = true
    }

    private func breadcrumb(_ message: String) -> Breadcrumb {
        let crumb = Breadcrumb(level: .info, category: "diagnostics")
        crumb.message = message
        return crumb
    }
}

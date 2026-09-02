import SwiftUI
import SanchrShared

/// `NSItemProvider` is not `Sendable`, but we only ever read it from the
/// loader's continuation closures (which already hop to a private queue
/// internally). Boxing the array in an `@unchecked Sendable` wrapper lets
/// us hand it to a SwiftUI `.task` under Swift 6 strict concurrency.
struct ShareProviders: @unchecked Sendable {
    let items: [NSItemProvider]
}

/// Top-level state for the share-extension flow.
///
/// The progression is strictly forward except for `error`, which is
/// terminal. The full graph is:
///
///     loadingPayload
///         -> locked          (if screen lock is on)
///         -> picker          (otherwise)
///         -> error           (load failure)
///
///     locked
///         -> loadingPayload  (after unlock; we re-run the loader because
///                            file URLs in the App Group cache survive but
///                            we want a single source of truth)
///
///     picker
///         -> composer
///         -> error           (cancellable)
///
///     composer
///         -> sending
///
///     sending
///         -> done            (terminal, calls onComplete)
///         -> error           (terminal)
///
enum ShareRootState: Equatable {
    case loadingPayload
    case locked
    case picker(SharePayload)
    case composer(SharePayload, recipients: [ShareChatSummary])
    case sending(SharePayload, recipients: [ShareChatSummary], caption: String?)
    case done
    case error(title: String, message: String)
}

struct ShareRootView: View {

    let providers: ShareProviders
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var state: ShareRootState = .loadingPayload

    /// Set by the unlock screen; see `isScreenLockEnabled`.

    @State private var hasUnlockedThisShare = false

    var body: some View {
        Group {
            switch state {
            case .loadingPayload:
                ProgressView("Loading\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
                    .task { await loadPayload(from: providers) }

            case .locked:
                ShareUnlockView(
                    onUnlocked: {
                        hasUnlockedThisShare = true
                        state = .loadingPayload
                    },
                    onCancel: onCancel
                )

            case .picker(let payload):
                ShareChatPickerView(
                    payload: payload,
                    onCancel: onCancel,
                    onNext: { recipients in
                        state = .composer(payload, recipients: recipients)
                    }
                )

            case .composer(let payload, let recipients):
                ShareComposerView(
                    payload: payload,
                    recipients: recipients,
                    onCancel: onCancel,
                    onSend: { caption in
                        state = .sending(payload, recipients: recipients, caption: caption)
                    }
                )

            case .sending(let payload, let recipients, let caption):
                ShareProgressSheet(
                    payload: payload,
                    recipients: recipients,
                    caption: caption,
                    onDone: {
                        state = .done
                        onComplete()
                    },
                    onCancel: onCancel,
                    driver: ShareSendCoordinator()
                )

            case .done:
                // Briefly visible before the host dismisses the extension.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))

            case .error(let title, let message):
                ShareErrorView(title: title, message: message, onDismiss: onCancel)
            }
        }
    }

    // MARK: - Payload loading

    private func loadPayload(from providers: ShareProviders) async {
        do {
            let payload = try await SharePayloadLoader.load(from: providers.items)
            if isScreenLockEnabled() {
                state = .locked
                // The picker will pick the payload back up after unlock by
                // re-running this method via the .loadingPayload arm. We
                // intentionally do not stash `payload` here so there is one
                // source of truth.
                _ = payload
            } else {
                state = .picker(payload)
            }
        } catch SharePayloadError.tooLarge(let bytes) {
            let mb = Double(bytes) / 1_048_576
            state = .error(
                title: "File is too large",
                message: String(
                    format: "This file is %.0f MB. Sanchr's share extension supports files up to 100 MB. Open Sanchr to send larger files.",
                    mb
                )
            )
        } catch SharePayloadError.unsupportedType {
            state = .error(
                title: "Unsupported",
                message: "Sanchr can't share this kind of content yet."
            )
        } catch SharePayloadError.nothingShared {
            state = .error(
                title: "Nothing to share",
                message: "The host app didn't pass any content."
            )
        } catch {
            state = .error(
                title: "Couldn't load",
                message: error.localizedDescription
            )
        }
    }

    /// Whether to gate this share behind the device's authentication.
    ///
    /// Reads the keys the app actually writes, through the shared definition.
    /// Once unlocked, stays unlocked for this share: `loadPayload` runs again
    /// after the unlock screen, and re-checking here would send the user
    /// straight back to it, forever.
    private func isScreenLockEnabled() -> Bool {
        !hasUnlockedThisShare && AppLockDefaultsKeys.isLockEnabled
    }
}


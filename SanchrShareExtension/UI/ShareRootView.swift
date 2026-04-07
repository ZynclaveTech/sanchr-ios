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
/// All non-loading/error states render stub views in this task — the real
/// unlock / picker / composer / progress views land in T23–T27.
enum ShareRootState: Equatable {
    case loadingPayload
    case locked
    case picker(SharePayload)
    case composer(SharePayload, selectedChatIds: [String])
    case sending(SharePayload, selectedChatIds: [String])
    case done
    case error(title: String, message: String)
}

struct ShareRootView: View {

    let providers: ShareProviders
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var state: ShareRootState = .loadingPayload

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
                    onUnlocked: { state = .loadingPayload },
                    onCancel: onCancel
                )

            case .picker(let payload):
                ShareChatPickerView(
                    payload: payload,
                    onCancel: onCancel,
                    onNext: { ids in
                        state = .composer(payload, selectedChatIds: ids)
                    }
                )

            case .composer(let payload, let ids):
                ShareComposerView(
                    payload: payload,
                    selectedChatIds: ids,
                    onCancel: onCancel,
                    onSend: {
                        state = .sending(payload, selectedChatIds: ids)
                    }
                )

            case .sending(let payload, let ids):
                ShareProgressSheet(
                    payload: payload,
                    chatIds: ids,
                    onDone: {
                        state = .done
                        onComplete()
                    },
                    onCancel: onCancel
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

    private func isScreenLockEnabled() -> Bool {
        AppGroup.userDefaults.bool(forKey: "screenLockEnabled")
    }
}

// MARK: - Stubs for T23–T27
//
// These views are placeholders so the state machine compiles in
// isolation. Each task in the next phase will replace its stub with the
// real implementation. Until then they render a labelled card and wire
// their callbacks to a single button so the flow can be exercised
// manually in the simulator.

struct ShareComposerView: View {
    let payload: SharePayload
    let selectedChatIds: [String]
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        ShareStubView(
            title: "Compose",
            subtitle: "Lands in Task 25",
            primaryLabel: "Send",
            primaryAction: onSend,
            secondaryAction: onCancel
        )
    }
}

struct ShareProgressSheet: View {
    let payload: SharePayload
    let chatIds: [String]
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ShareStubView(
            title: "Sending\u{2026}",
            subtitle: "Lands in Task 27",
            primaryLabel: "Done",
            primaryAction: onDone,
            secondaryAction: onCancel
        )
    }
}

private struct ShareStubView: View {
    let title: String
    let subtitle: String
    let primaryLabel: String
    let primaryAction: () -> Void
    let secondaryAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.footnote)
                .foregroundColor(SanchrExportColors.textSecondary)
            Button(primaryLabel, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .tint(SanchrColors.primary)
            Button("Cancel", action: secondaryAction)
                .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

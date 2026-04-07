import SwiftUI
import SanchrShared

/// Top-level SwiftUI surface hosted by `ShareViewController`.
///
/// In Task 21 this view only knows how to load the shared payload and
/// surface load failures — the full picker / composer / sending state
/// machine lands in Task 22 and beyond.
/// `NSItemProvider` is not `Sendable`, but we only ever read it from the
/// loader's continuation closures (which already hop to a private queue
/// internally). Boxing the array in an `@unchecked Sendable` wrapper lets
/// us hand it to a SwiftUI `.task` under Swift 6 strict concurrency.
struct ShareProviders: @unchecked Sendable {
    let items: [NSItemProvider]
}

struct ShareRootView: View {

    let providers: ShareProviders
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading
        case loaded(SharePayload)
        case error(title: String, message: String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Loading\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
                    .task { await loadPayload(from: providers) }
            case .loaded:
                // Real picker/composer flow lands in Task 22+. For now we
                // render a placeholder so the host can dismiss cleanly.
                ShareErrorView(
                    title: "Coming soon",
                    message: "Share-extension UI lands in the next task.",
                    onDismiss: onCancel
                )
            case .error(let title, let message):
                ShareErrorView(title: title, message: message, onDismiss: onCancel)
            }
        }
    }

    private func loadPayload(from providers: ShareProviders) async {
        do {
            let payload = try await SharePayloadLoader.load(from: providers.items)
            phase = .loaded(payload)
        } catch SharePayloadError.tooLarge(let bytes) {
            let mb = Double(bytes) / 1_048_576
            phase = .error(
                title: "File is too large",
                message: String(
                    format: "This file is %.0f MB. Sanchr's share extension supports files up to 100 MB. Open Sanchr to send larger files.",
                    mb
                )
            )
        } catch SharePayloadError.unsupportedType {
            phase = .error(
                title: "Unsupported",
                message: "Sanchr can't share this kind of content yet."
            )
        } catch SharePayloadError.nothingShared {
            phase = .error(
                title: "Nothing to share",
                message: "The host app didn't pass any content."
            )
        } catch {
            phase = .error(
                title: "Couldn't load",
                message: error.localizedDescription
            )
        }
    }
}

import SwiftUI
import SanchrShared

/// Drives the document-bubble QuickLook presentation. Handles the
/// resolve → decrypt → present flow asynchronously so the view can
/// show a progress overlay while the file lands on disk.
///
/// Reconfigure-able after init so `ChatDetailView` can construct it
/// as a `@StateObject` with bootstrap no-ops and swap in real
/// dependencies from `.task`.
@MainActor
final class DocumentPreviewCoordinator: ObservableObject {
    @Published var presentation: DocumentPresentation?
    @Published var isResolving: Bool = false
    @Published var resolveError: String?
    /// The file is gone for good; the alert should not read like a glitch.
    @Published var resolveErrorIsExpiry: Bool = false

    struct DocumentPresentation: Identifiable, Equatable {
        let id = UUID()
        let fileURL: URL
    }

    private var resolver: ChatMediaResolving
    private var messageLookup: (String) -> Message?

    init(
        resolver: ChatMediaResolving,
        messageLookup: @escaping (String) -> Message?
    ) {
        self.resolver = resolver
        self.messageLookup = messageLookup
    }

    func reconfigure(
        resolver: ChatMediaResolving,
        messageLookup: @escaping (String) -> Message?
    ) {
        self.resolver = resolver
        self.messageLookup = messageLookup
    }

    func open(messageId: String) async {
        guard let message = messageLookup(messageId),
              case .document(let media) = message.content,
              let attachment = media.first else {
            resolveError = "Attachment not found."
            return
        }
        isResolving = true
        defer { isResolving = false }
        do {
            let url = try await resolver.decryptedURLWithDisplayName(
                forMessageId: messageId,
                attachment: attachment
            )
            presentation = DocumentPresentation(fileURL: url)
        } catch {
            resolveErrorIsExpiry = (error as? AppError) == .mediaExpired
            resolveError = UserFacingError.message(for: error)
        }
    }

    func dismiss() {
        presentation = nil
    }

    func clearError() {
        resolveError = nil
        resolveErrorIsExpiry = false
    }
}

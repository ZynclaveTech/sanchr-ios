import SwiftUI
import SanchrShared

/// Drives the fullscreen image + video gallery presentation from
/// `ChatDetailView`. Stays separate from `ChatDetailViewModel` so the
/// view model stays `@Observable` without having to hold an
/// `ObservableObject` reference.
@MainActor
final class MediaGalleryCoordinator: ObservableObject {
    @Published var presentation: GalleryPresentation?

    struct GalleryPresentation: Identifiable, Equatable {
        let id = UUID()
        let items: [GalleryItem]
        let initialIndex: Int
    }

    func present(seed: GallerySeed) {
        presentation = GalleryPresentation(
            items: seed.items,
            initialIndex: seed.initialIndex
        )
    }

    func dismiss() {
        presentation = nil
    }
}

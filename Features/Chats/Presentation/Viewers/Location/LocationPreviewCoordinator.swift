import SwiftUI

/// Drives the location-bubble fullscreen preview. Holds nothing but
/// the latest presentation state — the view itself runs reverse-geocode
/// and opens maps directly.
@MainActor
final class LocationPreviewCoordinator: ObservableObject {
    @Published var presentation: LocationPresentation?

    struct LocationPresentation: Identifiable, Equatable {
        let id = UUID()
        let latitude: Double
        let longitude: Double
    }

    func present(latitude: Double, longitude: Double) {
        presentation = LocationPresentation(
            latitude: latitude,
            longitude: longitude
        )
    }

    func dismiss() {
        presentation = nil
    }
}

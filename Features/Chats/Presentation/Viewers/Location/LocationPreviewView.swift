import SwiftUI
import MapKit
import CoreLocation
import UIKit
import SanchrShared

/// Fullscreen location preview with a MapKit pin, reverse-geocoded
/// place name card, and an action sheet that routes the user to Apple
/// Maps, Google Maps, or the clipboard.
///
/// Privacy notes:
///   - `Map(position:)` in iOS 17+ does NOT render the receiver's own
///     blue-dot user location unless a `UserAnnotation()` is added to
///     the map content. We deliberately do not add one — the spec's
///     "receiver's own position must never be rendered" hardening is
///     satisfied by omission.
///   - Reverse geocoding sends the coordinate + device IP to Apple's
///     servers. Same threat model as MapKit tile fetches anywhere else
///     on iOS. Never sent if the user doesn't open the viewer.
struct LocationPreviewView: View {
    let latitude: Double
    let longitude: Double
    let onDismiss: () -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var placeName: String?
    @State private var toast: String?
    @State private var showActionSheet = false

    init(latitude: Double, longitude: Double, onDismiss: @escaping () -> Void) {
        self.latitude = latitude
        self.longitude = longitude
        self.onDismiss = onDismiss
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        self._cameraPosition = State(initialValue: .region(
            MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            )
        ))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition) {
                Marker(
                    placeName ?? "Shared location",
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                )
                .tint(SanchrColors.primary)
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()

            SanchrGlassCluster(spacing: 20) {
                HStack {
                    SanchrIconButton(
                        systemName: "xmark",
                        foreground: .black,
                        background: .white,
                        size: 36,
                        glassTint: Color.white.opacity(0.18)
                    ) {
                        onDismiss()
                    }

                    Spacer()

                    SanchrIconButton(
                        systemName: "square.and.arrow.up",
                        foreground: .black,
                        background: .white,
                        size: 36,
                        glassTint: Color.white.opacity(0.18)
                    ) {
                        showActionSheet = true
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 52)
        }
        .overlay(alignment: .bottom) {
            locationCard
        }
        .overlay(alignment: .bottom) {
            if let toast {
                SanchrToastBadge(text: toast)
                    .padding(.bottom, 140)
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation { self.toast = nil }
                    }
            }
        }
        .confirmationDialog(
            "Open location",
            isPresented: $showActionSheet,
            titleVisibility: .visible
        ) {
            Button("Open in Apple Maps") { openInAppleMaps() }
            Button("Open in Google Maps") { openInGoogleMaps() }
            Button("Copy Coordinates") { copyCoordinates() }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            await reverseGeocode()
        }
    }

    @ViewBuilder
    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let placeName {
                Text(placeName)
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            Text(String(format: "%.4f°, %.4f°", latitude, longitude))
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                showActionSheet = true
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                    Text("Directions")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .modifier(LocationDirectionsStyle())
        }
        .padding(14)
        .modifier(LocationCardSurfaceModifier())
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }
}

private struct LocationCardSurfaceModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .sanchrGlass(role: .viewerCard, tint: Color.white.opacity(0.08))
        } else {
            content
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 8, y: 4)
        }
    }
}

private struct LocationDirectionsStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content
                .foregroundColor(.white)
                .background(SanchrColors.primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private extension LocationPreviewView {
    // MARK: - Actions

    private func openInAppleMaps() {
        let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let placemark = MKPlacemark(coordinate: coord)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = placeName ?? "Shared location"
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }

    private func openInGoogleMaps() {
        let appURL = URL(string: "comgooglemaps://?q=\(latitude),\(longitude)&center=\(latitude),\(longitude)&zoom=15")
        let webURL = URL(string: "https://maps.google.com/?q=\(latitude),\(longitude)")
        if let appURL, UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else if let webURL {
            UIApplication.shared.open(webURL)
        }
    }

    private func copyCoordinates() {
        UIPasteboard.general.string = String(format: "%.6f, %.6f", latitude, longitude)
        toast = "Coordinates copied"
    }

    @MainActor
    private func reverseGeocode() async {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                let parts = [placemark.name, placemark.locality].compactMap { $0 }
                placeName = parts.isEmpty ? nil : parts.joined(separator: ", ")
            }
        } catch {
            // Silent: card falls back to coordinates only.
        }
    }
}

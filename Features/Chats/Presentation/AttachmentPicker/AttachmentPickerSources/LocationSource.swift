import Foundation
import CoreLocation

/// One-shot CLLocationManager. NEVER imports CLGeocoder or MKMapSnapshotter.
/// Manager is released as soon as requestOneShot returns.
final class LocationSource: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    enum Error: Swift.Error, Equatable { case denied, timeout, failed(String) }

    private let timeout: TimeInterval
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<CLLocation, Swift.Error>?
    private var timeoutTask: Task<Void, Never>?

    /// 15s default: first-time auth prompt + simulator + cold CL daemon can each
    /// eat several seconds. Test code overrides with a small value.
    init(timeout: TimeInterval = 15.0) {
        self.timeout = timeout
        super.init()
    }

    func requestOneShot() async throws -> LocationPayload {
        let location = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Swift.Error>) in
            self.continuation = cont
            let m = CLLocationManager()
            m.desiredAccuracy = kCLLocationAccuracyBest
            m.delegate = self
            self.manager = m

            switch m.authorizationStatus {
            case .notDetermined:
                m.requestWhenInUseAuthorization()
            case .denied, .restricted:
                self.resume(.failure(Error.denied))
                return
            case .authorizedWhenInUse, .authorizedAlways:
                m.requestLocation()
            @unknown default:
                self.resume(.failure(Error.failed("unknown auth status")))
                return
            }

            let to = self.timeout
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(to * 1_000_000_000))
                self?.resume(.failure(Error.timeout))
            }
        }
        return Self.makePayload(from: location)
    }

    static func makePayload(from location: CLLocation) -> LocationPayload {
        LocationPayload(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracyMeters: location.horizontalAccuracy,
            capturedAtUnixMs: Int64(location.timestamp.timeIntervalSince1970 * 1000)
        )
    }

    // MARK: Delegate
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
        case .denied, .restricted: resume(.failure(Error.denied))
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        resume(.success(loc))
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Swift.Error) {
        resume(.failure(Error.failed(error.localizedDescription)))
    }

    private func resume(_ result: Result<CLLocation, Swift.Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel(); timeoutTask = nil
        manager?.delegate = nil
        manager = nil
        switch result {
        case .success(let l): cont.resume(returning: l)
        case .failure(let e): cont.resume(throwing: e)
        }
    }
}

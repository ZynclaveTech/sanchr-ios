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
        print("[LocationSource] requestOneShot called, locationServicesEnabled=\(CLLocationManager.locationServicesEnabled())")
        let location = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Swift.Error>) in
            self.continuation = cont
            let m = CLLocationManager()
            m.desiredAccuracy = kCLLocationAccuracyBest
            m.delegate = self
            self.manager = m

            print("[LocationSource] initial authStatus=\(Self.describe(m.authorizationStatus))")
            switch m.authorizationStatus {
            case .notDetermined:
                print("[LocationSource] requesting whenInUse authorization")
                m.requestWhenInUseAuthorization()
                // Once permission is granted, locationManagerDidChangeAuthorization
                // calls startUpdatingLocation. Don't start before grant.
            case .denied, .restricted:
                print("[LocationSource] denied/restricted, resuming with .denied")
                self.resume(.failure(Error.denied))
                return
            case .authorizedWhenInUse, .authorizedAlways:
                // startUpdatingLocation is more reliable than requestLocation on
                // simulators and cold CL daemons — requestLocation can silently
                // do nothing if no recent fix is cached. We stop updating as soon
                // as the first location arrives in didUpdateLocations.
                print("[LocationSource] already authorized, calling startUpdatingLocation")
                m.startUpdatingLocation()
            @unknown default:
                self.resume(.failure(Error.failed("unknown auth status")))
                return
            }

            let to = self.timeout
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(to * 1_000_000_000))
                print("[LocationSource] timeout fired after \(to)s")
                self?.resume(.failure(Error.timeout))
            }
        }
        return Self.makePayload(from: location)
    }

    private static func describe(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(s.rawValue))"
        }
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
        case .authorizedWhenInUse, .authorizedAlways: m.startUpdatingLocation()
        case .denied, .restricted: resume(.failure(Error.denied))
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        // Stop updating immediately after the first usable fix.
        m.stopUpdatingLocation()
        resume(.success(loc))
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Swift.Error) {
        resume(.failure(Error.failed(error.localizedDescription)))
    }

    private func resume(_ result: Result<CLLocation, Swift.Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel(); timeoutTask = nil
        manager?.stopUpdatingLocation()
        manager?.delegate = nil
        manager = nil
        switch result {
        case .success(let l): cont.resume(returning: l)
        case .failure(let e): cont.resume(throwing: e)
        }
    }
}

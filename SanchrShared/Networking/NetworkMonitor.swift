import Combine
import Foundation
import Network

/// Protocol for observing network connectivity changes.
public protocol NetworkMonitorProtocol: AnyObject, Sendable {
    var isConnected: Bool { get }
    var connectionType: NetworkMonitor.ConnectionType { get }
    /// Stream of `isConnected` values. Emits the current value to new
    /// subscribers and a fresh event on every transition (duplicate
    /// non-transitions are suppressed at the source).
    var connectivityPublisher: AnyPublisher<Bool, Never> { get }
}

/// Monitors device network connectivity using NWPathMonitor.
public final class NetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
    public enum ConnectionType: Sendable {
        case wifi
        case cellular
        case wiredEthernet
        case none
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.sanchr.networkmonitor", qos: .utility)
    private let connectivitySubject = CurrentValueSubject<Bool, Never>(false)

    public private(set) var isConnected: Bool = false {
        didSet {
            if oldValue != isConnected {
                connectivitySubject.send(isConnected)
            }
        }
    }
    public private(set) var connectionType: ConnectionType = .none

    public var connectivityPublisher: AnyPublisher<Bool, Never> {
        connectivitySubject.eraseToAnyPublisher()
    }

    public init() {
        startMonitoring()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.isConnected = path.status == .satisfied
            self.connectionType = self.resolveConnectionType(path)

            SanchrLogger.network.info(
                "Network status changed: connected=\(self.isConnected), type=\(String(describing: self.connectionType))"
            )
        }
        monitor.start(queue: queue)
    }

    private func resolveConnectionType(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
        return .none
    }

    deinit {
        monitor.cancel()
    }
}

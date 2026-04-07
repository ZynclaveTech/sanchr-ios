import Combine
import Foundation
import Network

/// Protocol for observing network connectivity changes.
public protocol NetworkMonitorProtocol: AnyObject, Sendable {
    var isConnected: Bool { get }
    var connectionType: NetworkMonitor.ConnectionType { get }
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

    public private(set) var isConnected: Bool = false
    public private(set) var connectionType: ConnectionType = .none

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

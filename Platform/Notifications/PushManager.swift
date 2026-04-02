import Foundation
import UserNotifications
import UIKit

/// Protocol for push notification management.
protocol PushManagerProtocol: AnyObject, Sendable {
    func requestPermission() async throws -> Bool
    func registerDeviceToken(_ token: Data) async throws
    func handleNotification(userInfo: [AnyHashable: Any]) async
    var isPermissionGranted: Bool { get }
}

/// Manages APNs registration, permission requests, and notification handling.
final class PushManager: NSObject, PushManagerProtocol, @unchecked Sendable {
    private let grpcClient: GRPCClientProtocol
    private(set) var isPermissionGranted: Bool = false

    init(grpcClient: GRPCClientProtocol) {
        self.grpcClient = grpcClient
        super.init()
    }

    func requestPermission() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        isPermissionGranted = granted

        if granted {
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
            SanchrLogger.push.info("Push notification permission granted")
        } else {
            SanchrLogger.push.info("Push notification permission denied")
        }

        return granted
    }

    func registerDeviceToken(_ token: Data) async throws {
        let tokenString = token.map { String(format: "%02.2hhx", $0) }.joined()
        SanchrLogger.push.info("Registering device token: \(tokenString.prefix(8))...")

        // TODO: Send device token to backend via gRPC
        // try await grpcClient.pushService.registerToken(tokenString)
    }

    func handleNotification(userInfo: [AnyHashable: Any]) async {
        SanchrLogger.push.info("Handling push notification")

        // TODO: Parse notification payload and route accordingly
        // - New message: navigate to chat
        // - Incoming call: present call UI via CallKit
        // - Key verification: navigate to security settings
    }
}

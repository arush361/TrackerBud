import Foundation
import UserNotifications
import OSLog

public final class NotificationsManager: @unchecked Sendable {
    public static let shared = NotificationsManager()

    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "Notifications")
    public init() {}

    public func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        if current.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            } catch {
                log.error("Notification auth request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Schedule a one-shot notification at a specific date.
    public func scheduleOneShot(identifier: String, title: String, body: String, at date: Date) async throws {
        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["tb_route": "insights"]

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }

    /// Fire immediately, useful for "your digest is ready" notifications.
    public func fireImmediate(identifier: String, title: String, body: String) async throws {
        await requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["tb_route": "insights"]
        // Use a 1-second trigger; macOS dislikes immediate-delivery (nil trigger).
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }

    public func cancel(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

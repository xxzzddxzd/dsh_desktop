import Foundation
import UserNotifications

/// System notification front for the menu bar app (banner + sound, also
/// presented while the app is frontmost).
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var authorized = false

    func requestIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
            if !granted {
                LogStore.shared.append("系统通知未获授权（可在「系统设置 › 通知」中开启）", source: "desktop")
            }
        }
    }

    func notify(id: String, title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "dsh-\(id)-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

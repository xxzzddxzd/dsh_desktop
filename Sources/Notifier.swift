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
            if granted { self?.clear(prefix: "agent-error-") }
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
        let identifier = "dsh-\(id)"
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func clear(id: String) {
        let identifier = "dsh-\(id)"
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func clear(prefix idPrefix: String) {
        let prefix = "dsh-\(idPrefix)"
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notes in
            center.removeDeliveredNotifications(withIdentifiers: notes.map(\.request.identifier).filter { $0.hasPrefix(prefix) })
        }
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

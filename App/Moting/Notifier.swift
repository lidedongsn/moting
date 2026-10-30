import AppKit
import UserNotifications

/// 系统通知：会后转写完成后提示，点击打开该会议
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// 在主线程回调被点击的会议 id
    var onOpenMeeting: (@MainActor (UUID) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, meetingID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["meetingID": meetingID.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: meetingID.uuidString, content: content, trigger: nil))
    }

    // 这些代理方法由系统在后台线程调用：标为 nonisolated，内部再切回主线程
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["meetingID"] as? String).flatMap(UUID.init(uuidString:))
        completionHandler()
        guard let id else { return }
        Task { @MainActor [weak self] in self?.onOpenMeeting?(id) }
    }
}

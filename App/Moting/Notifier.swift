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

    /// meetingID 为空时只是提示，点击不打开会议
    func post(title: String, body: String, meetingID: UUID?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let meetingID { content.userInfo = ["meetingID": meetingID.uuidString] }
        // 每条通知用新标识：同一场会议先后发"转写完成""纪要已生成"时，
        // 若标识相同，系统只会悄悄替换通知中心里的旧条目，不再弹横幅
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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

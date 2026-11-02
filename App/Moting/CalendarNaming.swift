import EventKit
import MotingCore

/// 用日历事件给会议命名（默认关闭；打开时才请求日历权限）。只在本机读取，不上传
enum CalendarNaming {
    static let enabledKey = "calendarNaming.enabled"

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) && isAuthorized
    }

    /// 请求日历权限；已拒绝过时系统不会再弹，返回 false
    static func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// 现在正在开（或十分钟内开始）的会议标题
    static func currentTitle(at now: Date = Date()) -> String? {
        guard isEnabled else { return nil }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: now - CalendarMatch.maxLength,
                                                 end: now + CalendarMatch.earlyStart, calendars: nil)
        let events = store.events(matching: predicate).map {
            CalendarMatch.Event(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay)
        }
        return CalendarMatch.title(for: events, at: now)
    }
}

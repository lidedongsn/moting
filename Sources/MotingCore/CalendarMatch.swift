import Foundation

/// 开始录音时从日历里挑出"正在开的这场会"，用它的标题给会议命名
public enum CalendarMatch {
    public struct Event: Sendable {
        public var title: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool

        public init(title: String, start: Date, end: Date, isAllDay: Bool) {
            self.title = title
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
        }
    }

    /// 允许提前这么久开始录（提前进会议室）
    public static let earlyStart: TimeInterval = 10 * 60
    /// 超过这么长的事件（如"工作时间"、出差）不算会议
    public static let maxLength: TimeInterval = 4 * 3600

    /// 正在进行或即将开始的会议标题；有几场重叠时取开始时间离现在最近的
    public static func title(for events: [Event], at now: Date) -> String? {
        events
            .filter { e in
                !e.isAllDay && e.end > now && e.start <= now + earlyStart
                    && e.end.timeIntervalSince(e.start) <= maxLength
                    && !e.title.trimmingCharacters(in: .whitespaces).isEmpty
            }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }?
            .title.trimmingCharacters(in: .whitespaces)
    }
}

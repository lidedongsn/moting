import Foundation

public enum MeetingGroup: String, CaseIterable, Sendable {
    case today, yesterday, thisWeek, earlier

    public var title: String {
        switch self {
        case .today: L("今天")
        case .yesterday: L("昨天")
        case .thisWeek: L("本周")
        case .earlier: L("更早")
        }
    }
}

/// 侧栏分组：按本地日历判断今天 / 昨天 / 本周 / 更早；组内保持传入顺序，空组省略
public enum MeetingGrouping {
    public static func group(_ meetings: [Meeting], now: Date, calendar: Calendar) -> [(MeetingGroup, [Meeting])] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfYesterday
        var buckets: [MeetingGroup: [Meeting]] = [:]
        for m in meetings.sorted(by: { $0.startedAt > $1.startedAt }) {
            let g: MeetingGroup
            if m.startedAt >= startOfToday { g = .today }
            else if m.startedAt >= startOfYesterday { g = .yesterday }
            else if m.startedAt >= startOfWeek { g = .thisWeek }
            else { g = .earlier }
            buckets[g, default: []].append(m)
        }
        return MeetingGroup.allCases.compactMap { g in buckets[g].map { (g, $0) } }
    }
}

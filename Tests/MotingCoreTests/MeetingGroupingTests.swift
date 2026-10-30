import Foundation
import Testing
@testable import MotingCore

@Test func groupsByLocalCalendar() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    cal.firstWeekday = 2   // 周一
    let f = ISO8601DateFormatter()
    // 现在：2026-10-30 周五 00:30（北京时间）
    let now = f.date(from: "2026-10-29T16:30:00Z")!
    func m(_ iso: String) -> Meeting { Meeting(id: UUID(), title: iso, startedAt: f.date(from: iso)!, endedAt: nil, status: .done) }
    let today = m("2026-10-29T16:10:00Z")       // 周五 00:10
    let yesterday = m("2026-10-29T15:50:00Z")   // 周四 23:50（跨午夜）
    let monday = m("2026-10-26T01:00:00Z")      // 本周一 09:00
    let lastSunday = m("2026-10-25T15:00:00Z")  // 上周日 23:00
    let groups = MeetingGrouping.group([lastSunday, monday, yesterday, today], now: now, calendar: cal)
    #expect(groups.map(\.0) == [.today, .yesterday, .thisWeek, .earlier])
    #expect(groups.map { $0.1.map(\.title) } == [[today.title], [yesterday.title], [monday.title], [lastSunday.title]])
}

@Test func emptyGroupsAreOmitted() {
    let now = Date()
    let groups = MeetingGrouping.group([Meeting(id: UUID(), title: "a", startedAt: now, endedAt: nil, status: .done)],
                                       now: now, calendar: .current)
    #expect(groups.map(\.0) == [.today])
}

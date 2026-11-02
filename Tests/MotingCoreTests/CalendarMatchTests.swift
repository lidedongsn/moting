import Foundation
import Testing
@testable import MotingCore

private let now = ISO8601DateFormatter().date(from: "2026-11-02T06:00:00Z")!

private func ev(_ title: String, _ startMin: Double, _ endMin: Double, allDay: Bool = false) -> CalendarMatch.Event {
    CalendarMatch.Event(title: title, start: now + startMin * 60, end: now + endMin * 60, isAllDay: allDay)
}

@Test func picksEventInProgress() {
    #expect(CalendarMatch.title(for: [ev("周会", -5, 55)], at: now) == "周会")
}

@Test func picksEventStartingSoon() {
    // 提前几分钟进会议室开始录
    #expect(CalendarMatch.title(for: [ev("评审", 8, 68)], at: now) == "评审")
    #expect(CalendarMatch.title(for: [ev("评审", 20, 80)], at: now) == nil)
}

@Test func ignoresEndedAllDayAndVeryLongEvents() {
    #expect(CalendarMatch.title(for: [ev("早会", -60, -1)], at: now) == nil)
    #expect(CalendarMatch.title(for: [ev("出差", -300, 900, allDay: true)], at: now) == nil)
    #expect(CalendarMatch.title(for: [ev("工作时间", -120, 400)], at: now) == nil)
}

@Test func prefersEventWhoseStartIsClosest() {
    let events = [ev("长会", -50, 10), ev("站会", -2, 13), ev("下一个", 9, 30)]
    #expect(CalendarMatch.title(for: events, at: now) == "站会")
}

@Test func ignoresBlankTitles() {
    #expect(CalendarMatch.title(for: [ev("  ", -5, 55)], at: now) == nil)
}

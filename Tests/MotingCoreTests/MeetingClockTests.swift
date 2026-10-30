import Foundation
import Testing
@testable import MotingCore

@Test func elapsedExcludesPauses() {
    var c = MeetingClock()
    let t0 = Date(timeIntervalSince1970: 0)
    c.start(at: t0)
    c.pause(at: t0 + 10)
    c.resume(at: t0 + 25)
    #expect(c.elapsed(at: t0 + 30) == 15)
}

@Test func elapsedDuringPauseIsFrozen() {
    var c = MeetingClock()
    let t0 = Date(timeIntervalSince1970: 0)
    c.start(at: t0)
    c.pause(at: t0 + 10)
    #expect(c.isPaused)
    #expect(c.elapsed(at: t0 + 20) == 10)
}

@Test func pauseAndResumeAreIdempotent() {
    var c = MeetingClock()
    let t0 = Date(timeIntervalSince1970: 0)
    c.start(at: t0)
    c.pause(at: t0 + 5)
    c.pause(at: t0 + 8)
    c.resume(at: t0 + 10)
    c.resume(at: t0 + 11)
    #expect(c.elapsed(at: t0 + 20) == 15)
}

@Test func elapsedBeforeStartIsZero() {
    #expect(MeetingClock().elapsed(at: Date()) == 0)
}

@Test func defaultTitle() {
    let m = Meeting.new(startedAt: ISO8601DateFormatter().date(from: "2026-10-30T06:05:00Z")!)
    #expect(m.title.hasPrefix("会议 2026-10-30"))
    #expect(m.status == .recording)
    #expect(m.endedAt == nil)
}

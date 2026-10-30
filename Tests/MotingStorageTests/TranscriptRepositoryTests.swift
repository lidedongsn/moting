import Foundation
import Testing
import MotingCore
@testable import MotingStorage

private func setup() throws -> (MeetingRepository, TranscriptRepository, Meeting) {
    let db = try AppDatabase.inMemory()
    let meetings = MeetingRepository(db: db)
    let m = Meeting(id: UUID(), title: "t", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, status: .recording)
    try meetings.insert(m, tracks: [])
    return (meetings, TranscriptRepository(db: db), m)
}

private func seg(_ v: UUID, _ start: TimeInterval, _ text: String, _ ch: AudioChannel = .mic) -> TranscriptSegment {
    TranscriptSegment(id: UUID(), versionID: v, channel: ch, speakerLabel: nil, start: start, end: start + 1, text: text)
}

@Test func segmentsRoundTripInStartOrder() throws {
    let (_, repo, m) = try setup()
    let v = try repo.createVersion(meetingID: m.id, kind: .draft, engine: "e", model: "m", createdAt: Date())
    let a = seg(v, 5, "三", .system), b = seg(v, 1, "一"), c = seg(v, 3, "二")
    for s in [a, b, c] { try repo.append(s) }
    #expect(try repo.segments(versionID: v) == [b, c, a])
}

@Test func latestVersionPicksNewest() throws {
    let (_, repo, m) = try setup()
    _ = try repo.createVersion(meetingID: m.id, kind: .draft, engine: "e", model: "m", createdAt: Date(timeIntervalSince1970: 10))
    let newer = try repo.createVersion(meetingID: m.id, kind: .draft, engine: "e", model: "m", createdAt: Date(timeIntervalSince1970: 20))
    #expect(try repo.latestVersion(meetingID: m.id, kind: .draft) == newer)
    #expect(try repo.latestVersion(meetingID: m.id, kind: .final) == nil)
}

@Test func deletingMeetingCascades() throws {
    let (meetings, repo, m) = try setup()
    let v = try repo.createVersion(meetingID: m.id, kind: .draft, engine: "e", model: "m", createdAt: Date())
    try repo.append(seg(v, 0, "你好"))
    try meetings.delete(m.id)
    #expect(try repo.segments(versionID: v).isEmpty)
    #expect(try repo.latestVersion(meetingID: m.id, kind: .draft) == nil)
}

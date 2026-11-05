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

@Test func unfinishedFinalVersionIsHidden() throws {
    let (_, repo, m) = try setup()
    let v = try repo.createVersion(meetingID: m.id, kind: .final, engine: "e", model: "m", createdAt: Date())
    #expect(try repo.latestVersion(meetingID: m.id, kind: .final) == nil)
    try repo.markCompleted(v, at: Date())
    #expect(try repo.latestVersion(meetingID: m.id, kind: .final) == v)
}

@Test func deleteVersionRemovesSegments() throws {
    let (_, repo, m) = try setup()
    let v = try repo.createVersion(meetingID: m.id, kind: .final, engine: "e", model: "m", createdAt: Date())
    try repo.append(seg(v, 0, "一"))
    try repo.deleteVersion(v)
    #expect(try repo.segments(versionID: v).isEmpty)
}

@Test func searchFindsTranscriptText() throws {
    let (meetings, repo, m) = try setup()
    let other = Meeting(id: UUID(), title: "o", startedAt: Date(), endedAt: nil, status: .done)
    try meetings.insert(other, tracks: [])
    let v = try repo.createVersion(meetingID: m.id, kind: .draft, engine: "e", model: "m", createdAt: Date())
    try repo.append(seg(v, 0, "测试环境谁来搭"))
    #expect(try repo.meetingIDs(matching: "环境") == [m.id])
    #expect(try repo.meetingIDs(matching: "不存在的词").isEmpty)
    #expect(try repo.meetingIDs(matching: "100%_").isEmpty)   // 通配符按普通字符处理
}

// MARK: - 手动编辑

private func editFixture() throws -> (TranscriptRepository, UUID, TranscriptSegment) {
    let db = try AppDatabase.inMemory()
    let meetings = MeetingRepository(db: db)
    let m = Meeting(id: UUID(), title: "t", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, status: .done)
    try meetings.insert(m, tracks: [])
    let repo = TranscriptRepository(db: db)
    let v = try repo.createVersion(meetingID: m.id, kind: .final, engine: "e", model: "m", createdAt: Date())
    let s = TranscriptSegment(versionID: v, channel: .mic, start: 1, end: 2, text: "原来的错字")
    try repo.append(s)
    return (repo, v, s)
}

@Test func editingKeepsTheOriginalText() throws {
    let (repo, v, s) = try editFixture()
    #expect(try !repo.hasEdits(versionID: v))
    try repo.setText(segmentID: s.id, text: "改好的文字")
    let got = try #require(try repo.segments(versionID: v).first)
    #expect(got.text == "改好的文字")
    #expect(got.originalText == "原来的错字")
    #expect(got.isEdited)
    #expect(got.start == 1 && got.end == 2, "时间不变，点句播放才准")
    #expect(try repo.hasEdits(versionID: v))
}

@Test func secondEditStillRemembersTheFirstOriginal() throws {
    let (repo, v, s) = try editFixture()
    try repo.setText(segmentID: s.id, text: "第一次")
    try repo.setText(segmentID: s.id, text: "第二次")
    let got = try #require(try repo.segments(versionID: v).first)
    #expect(got.text == "第二次")
    #expect(got.originalText == "原来的错字")
}

@Test func restoringReturnsToRecognizedText() throws {
    let (repo, v, s) = try editFixture()
    try repo.setText(segmentID: s.id, text: "改好的文字")
    try repo.restoreText(segmentID: s.id)
    let got = try #require(try repo.segments(versionID: v).first)
    #expect(got.text == "原来的错字")
    #expect(!got.isEdited)
    #expect(try !repo.hasEdits(versionID: v))
}

@Test func typingTheOriginalBackIsNotAnEdit() throws {
    let (repo, v, s) = try editFixture()
    try repo.setText(segmentID: s.id, text: "改好的文字")
    try repo.setText(segmentID: s.id, text: "原来的错字")
    #expect(try !repo.hasEdits(versionID: v))
}

@Test func savingUnchangedTextIsNotAnEdit() throws {
    let (repo, v, s) = try editFixture()
    try repo.setText(segmentID: s.id, text: "原来的错字")
    #expect(try !repo.hasEdits(versionID: v))
}

@Test func blankTextIsIgnoredSoASentenceCannotVanishByAccident() throws {
    let (repo, v, s) = try editFixture()
    try repo.setText(segmentID: s.id, text: "   \n")
    let got = try #require(try repo.segments(versionID: v).first)
    #expect(got.text == "原来的错字")
    #expect(!got.isEdited)
}

@Test func editedTextIsFoundBySearchAndOldTextIsNot() throws {
    let (repo, v, s) = try editFixture()
    try repo.setText(segmentID: s.id, text: "新的专有名词")
    let meeting = try #require(try repo.meetingID(ofVersion: v))
    #expect(try repo.meetingIDs(matching: "专有名词") == [meeting])
    #expect(try repo.meetingIDs(matching: "错字").isEmpty)
}

@Test func meetingHasEditsLooksAtTheLatestFinalTranscript() throws {
    let (repo, v, s) = try editFixture()
    let meeting = try #require(try repo.meetingID(ofVersion: v))
    try repo.markCompleted(v, at: Date())
    #expect(try !repo.finalTranscriptHasEdits(meetingID: meeting))
    try repo.setText(segmentID: s.id, text: "改好的文字")
    #expect(try repo.finalTranscriptHasEdits(meetingID: meeting))
}

@Test func removedSentenceDisappearsButCountsAsAnEditAndCanComeBack() throws {
    let (repo, v, s) = try editFixture()
    try repo.removeSegment(s.id)
    #expect(try repo.segments(versionID: v).isEmpty)
    #expect(try repo.hasEdits(versionID: v))
    let meeting = try #require(try repo.meetingID(ofVersion: v))
    #expect(try repo.meetingIDs(matching: "错字").isEmpty)
    try repo.restoreAll(versionID: v)
    let got = try #require(try repo.segments(versionID: v).first)
    #expect(got.text == "原来的错字")
    #expect(!got.isEdited)
    #expect(try repo.meetingIDs(matching: "错字") == [meeting])
}

@Test func removingAnEditedSentenceRemembersTheRecognizedText() throws {
    let (repo, v, s) = try editFixture()
    try repo.setText(segmentID: s.id, text: "改过")
    try repo.removeSegment(s.id)
    try repo.restoreAll(versionID: v)
    #expect(try repo.segments(versionID: v).first?.text == "原来的错字")
}

@Test func restoreAllOnlyTouchesEditedSentences() throws {
    let (repo, v, s) = try editFixture()
    let other = TranscriptSegment(versionID: v, channel: .system, start: 3, end: 4, text: "没动过")
    try repo.append(other)
    try repo.setText(segmentID: s.id, text: "改过")
    try repo.restoreAll(versionID: v)
    #expect(try repo.segments(versionID: v).map(\.text) == ["原来的错字", "没动过"])
    #expect(try !repo.hasEdits(versionID: v))
}

import Foundation
import Testing
import MotingCore
@testable import MotingStorage

private func setup() throws -> (AppDatabase, MeetingRepository, JobRepository, Meeting) {
    let db = try AppDatabase.inMemory()
    let meetings = MeetingRepository(db: db)
    let m = Meeting(id: UUID(), title: "t", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, status: .pendingProcessing)
    try meetings.insert(m, tracks: [])
    return (db, meetings, JobRepository(db: db), m)
}

@Test func enqueueIsIdempotentPerMeeting() throws {
    let (_, _, jobs, m) = try setup()
    let a = try jobs.enqueue(meetingID: m.id, modelID: "x", status: .queued, at: Date(timeIntervalSince1970: 1))
    let b = try jobs.enqueue(meetingID: m.id, modelID: "x", status: .queued, at: Date(timeIntervalSince1970: 2))
    #expect(a.id == b.id)
    var done = a
    done.status = .done
    try jobs.update(done)
    let c = try jobs.enqueue(meetingID: m.id, modelID: "y", status: .queued, at: Date(timeIntervalSince1970: 3))
    #expect(c.id != a.id)
    #expect(try jobs.job(for: m.id)?.id == c.id)
}

@Test func nextSkipsWaitingForPowerAndDone() throws {
    let (_, meetings, jobs, m) = try setup()
    let m2 = Meeting(id: UUID(), title: "t2", startedAt: Date(timeIntervalSince1970: 5), endedAt: nil, status: .pendingProcessing)
    try meetings.insert(m2, tracks: [])
    _ = try jobs.enqueue(meetingID: m.id, modelID: "x", status: .waitingForPower, at: Date(timeIntervalSince1970: 1))
    let q = try jobs.enqueue(meetingID: m2.id, modelID: "x", status: .queued, at: Date(timeIntervalSince1970: 2))
    #expect(try jobs.next()?.id == q.id)
    var d = q
    d.status = .done
    try jobs.update(d)
    #expect(try jobs.next() == nil)
}

@Test func staleRunningJobIsRequeued() throws {
    let (_, _, jobs, m) = try setup()
    var j = try jobs.enqueue(meetingID: m.id, modelID: "x", status: .queued, at: Date())
    j.status = .running
    j.completedSteps = [.transcribe]
    try jobs.update(j)
    #expect(try jobs.requeueStaleRunning() == 1)
    let back = try #require(try jobs.job(for: m.id))
    #expect(back.status == .queued)
    #expect(back.completedSteps == [.transcribe])
}

@Test func jobFieldsRoundTrip() throws {
    let (_, _, jobs, m) = try setup()
    var j = try jobs.enqueue(meetingID: m.id, modelID: "x", status: .queued, at: Date(timeIntervalSince1970: 7))
    j.completedSteps = [.transcribe, .diarize]
    j.progress = 0.5
    j.error = "坏了"
    j.versionID = UUID()
    j.filterOutcome = "fellBack"
    try jobs.update(j)
    #expect(try jobs.job(for: m.id) == j)
}

@Test func speakerNamesRoundTripAndBlankResets() throws {
    let (db, _, _, m) = try setup()
    let speakers = SpeakerRepository(db: db)
    try speakers.setName(meetingID: m.id, label: "说话人 1", name: " 张三 ")
    #expect(try speakers.names(meetingID: m.id) == ["说话人 1": "张三"])
    try speakers.setName(meetingID: m.id, label: "说话人 1", name: "  ")
    #expect(try speakers.names(meetingID: m.id).isEmpty)
}

@Test func deletingMeetingCascadesJobsAndSpeakers() throws {
    let (db, meetings, jobs, m) = try setup()
    _ = try jobs.enqueue(meetingID: m.id, modelID: "x", status: .queued, at: Date())
    try SpeakerRepository(db: db).setName(meetingID: m.id, label: "说话人 1", name: "张三")
    try meetings.delete(m.id)
    #expect(try jobs.job(for: m.id) == nil)
    #expect(try SpeakerRepository(db: db).names(meetingID: m.id).isEmpty)
}

@Test func jobThatKeepsDyingStopsRetryingAfterSecondInterruption() throws {
    // 原生库直接退出时不会走到错误处理：不停重试就是打开 app 就退
    let (_, repo, jobs, m) = try setup()
    var j = try jobs.enqueue(meetingID: m.id, modelID: "x", status: .queued, at: Date())
    j.status = .running
    try jobs.update(j)
    #expect(try jobs.requeueStaleRunning() == 1)
    #expect(try jobs.job(for: m.id)?.status == .queued)
    #expect(try jobs.job(for: m.id)?.interruptions == 1)

    var again = try #require(try jobs.job(for: m.id))
    again.status = .running
    try jobs.update(again)
    #expect(try jobs.requeueStaleRunning() == 0)
    let failed = try #require(try jobs.job(for: m.id))
    #expect(failed.status == .failed)
    #expect(failed.error?.isEmpty == false)
    #expect(try repo.meeting(m.id)?.status == .failed)
    #expect(try jobs.next() == nil)
}

@Test func retryAfterFailureStartsWithACleanCount() throws {
    let (_, _, jobs, m) = try setup()
    var j = try jobs.enqueue(meetingID: m.id, modelID: "x", status: .queued, at: Date())
    j.interruptions = 2
    j.status = .failed
    try jobs.update(j)
    #expect(try jobs.enqueue(meetingID: m.id, modelID: "x", status: .queued, at: Date()).interruptions == 0)
}

import Foundation
import Testing
import MotingCore
import MotingStorage
@testable import MotingPipeline

/// 记录调用、可在指定步骤抛错的假步骤执行器
final class FakeSteps: PipelineStepRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [JobStep] = []
    var failAt: JobStep?
    /// 在这一步一直跑，直到任务被取消（模拟耗时步骤）
    var hangAt: JobStep?
    var calls: [JobStep] { lock.withLock { _calls } }

    func run(_ step: JobStep, job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> Job {
        lock.withLock { _calls.append(step) }
        progress(0.5)
        if step == hangAt {
            while !Task.isCancelled { await Task.yield() }
            throw CancellationError()
        }
        progress(1.0)
        if step == failAt { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(step) 失败"]) }
        var j = job
        if step == .transcribe { j.versionID = UUID() }
        return j
    }
}

final class FakePower: PowerSource, @unchecked Sendable {
    var isOnAC: Bool
    init(_ ac: Bool) { isOnAC = ac }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool
    init(_ v: Bool) { self.v = v }
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.withLock { values.append(v) } }
    var all: [Double] { lock.withLock { values } }
}

private struct Fixture {
    let meetings: MeetingRepository
    let jobs: JobRepository
    let steps = FakeSteps()
    let power: FakePower
    let recording: Flag
    let runner: PipelineRunner
    let meeting: Meeting

    init(onAC: Bool = true, recording: Flag = Flag(false), sleep: (@Sendable (Duration) async -> Void)? = nil) throws {
        self.recording = recording
        let db = try AppDatabase.inMemory()
        meetings = MeetingRepository(db: db)
        jobs = JobRepository(db: db)
        power = FakePower(onAC)
        meeting = Meeting(id: UUID(), title: "t", startedAt: Date(timeIntervalSince1970: 0),
                          endedAt: Date(timeIntervalSince1970: 60), status: .pendingProcessing)
        try meetings.insert(meeting, tracks: [])
        let recording = recording
        runner = PipelineRunner(jobs: jobs, meetings: meetings, steps: steps, power: power,
                                isRecording: { recording.value }, sleep: sleep ?? { _ in await Task.yield() })
    }
}

@Test func runsStepsInOrderAndMarksDone() async throws {
    let f = try Fixture()
    _ = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    await f.runner.drain()
    #expect(f.steps.calls == JobStep.allCases)
    let job = try #require(try f.jobs.job(for: f.meeting.id))
    #expect(job.status == .done)
    #expect(job.progress == 1)
    #expect(job.versionID != nil)
    #expect(try f.meetings.meeting(f.meeting.id)?.status == .done)
    #expect(try f.meetings.meeting(f.meeting.id)?.endedAt == f.meeting.endedAt)
}

@Test func resumesFromLastCompletedStep() async throws {
    let f = try Fixture()
    var job = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    job.completedSteps = [.transcribe]
    try f.jobs.update(job)
    await f.runner.drain()
    #expect(f.steps.calls == [.diarize, .filterVoice, .merge])
}

@Test func failureMarksMeetingFailedWithError() async throws {
    let f = try Fixture()
    f.steps.failAt = .diarize
    _ = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    await f.runner.drain()
    let job = try #require(try f.jobs.job(for: f.meeting.id))
    #expect(job.status == .failed)
    #expect(job.completedSteps == [.transcribe])
    #expect(job.error?.contains("diarize") == true)
    #expect(try f.meetings.meeting(f.meeting.id)?.status == .failed)
}

@Test func waitsForPowerOnBattery() async throws {
    let f = try Fixture(onAC: false)
    let job = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    #expect(job.status == .waitingForPower)
    await f.runner.drain()
    #expect(f.steps.calls.isEmpty)
    try f.runner.processNow(meetingID: f.meeting.id)
    await f.runner.drain()
    #expect(f.steps.calls == JobStep.allCases)
}

@Test func pluggingInReleasesWaitingJobs() async throws {
    let f = try Fixture(onAC: false)
    _ = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    f.power.isOnAC = true
    try f.runner.powerChanged()
    await f.runner.drain()
    #expect(try f.jobs.job(for: f.meeting.id)?.status == .done)
}

@Test func pausesWhileRecording() async throws {
    let sleeps = ProgressLog()
    let rec = Flag(true)
    let f = try Fixture(recording: rec, sleep: { _ in
        sleeps.add(1)
        // 等 3 次之后录音结束
        if sleeps.all.count >= 3 { rec.value = false }
        await Task.yield()
    })
    _ = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    await f.runner.drain()
    #expect(sleeps.all.count == 3)
    #expect(f.steps.calls == JobStep.allCases)
}

@Test func progressIsMonotonic() async throws {
    let f = try Fixture()
    let log = ProgressLog()
    f.runner.onProgress = { _, p in log.add(p) }
    _ = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    await f.runner.drain()
    #expect(!log.all.isEmpty)
    #expect(zip(log.all, log.all.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(log.all.last == 1)
}

@Test func staleRunningJobIsRequeuedOnStart() async throws {
    let f = try Fixture()
    var job = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    job.status = .running
    job.completedSteps = [.transcribe, .diarize]
    try f.jobs.update(job)
    try f.runner.recoverAfterLaunch()
    await f.runner.drain()
    #expect(f.steps.calls == [.filterVoice, .merge])
}

@Test func pauseStopsRunningJobAndResumeContinuesFromBreakpoint() async throws {
    let f = try Fixture()
    f.steps.hangAt = .diarize
    _ = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    let drain = Task { await f.runner.drain() }
    while f.steps.calls.count < 2 { await Task.yield() }
    try f.runner.pause(meetingID: f.meeting.id)
    await drain.value
    var job = try #require(try f.jobs.job(for: f.meeting.id))
    #expect(job.status == .paused)
    #expect(job.completedSteps == [.transcribe])

    f.steps.hangAt = nil
    try f.runner.resume(meetingID: f.meeting.id)
    await f.runner.drain()
    job = try #require(try f.jobs.job(for: f.meeting.id))
    #expect(job.status == .done)
    #expect(f.steps.calls == [.transcribe, .diarize, .diarize, .filterVoice, .merge])
}

@Test func pausedQueuedJobIsSkipped() async throws {
    let f = try Fixture()
    _ = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    try f.runner.pause(meetingID: f.meeting.id)
    await f.runner.drain()
    #expect(f.steps.calls.isEmpty)
    #expect(try f.jobs.job(for: f.meeting.id)?.status == .paused)
}

@Test func enqueueResumesPausedJob() async throws {
    let f = try Fixture()
    _ = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    try f.runner.pause(meetingID: f.meeting.id)
    _ = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    await f.runner.drain()
    #expect(try f.jobs.job(for: f.meeting.id)?.status == .done)
}

@Test func pausingDoesNotReportProgressAfterwards() async throws {
    // 回归：暂停分支曾回报一次进度，界面据此把"已暂停"改回"转写中"，任务卡住
    let f = try Fixture()
    f.steps.hangAt = .diarize
    let log = ProgressLog()
    let paused = Flag(false)
    f.runner.onProgress = { _, p in if paused.value { log.add(p) } }
    _ = try f.runner.enqueue(meetingID: f.meeting.id, modelID: "m")
    let drain = Task { await f.runner.drain() }
    while f.steps.calls.count < 2 { await Task.yield() }
    paused.value = true
    try f.runner.pause(meetingID: f.meeting.id)
    await drain.value
    #expect(try f.jobs.job(for: f.meeting.id)?.status == .paused)
    #expect(log.all.isEmpty, "暂停后不应再回报进度：\(log.all)")
}

import Foundation
import MotingCore
import MotingStorage

/// 一个步骤的执行者；返回的 Job 可携带步骤产出（如正式稿版本 id、声纹过滤结果）
public protocol PipelineStepRunner: Sendable {
    func run(_ step: JobStep, job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> Job
}

/// 会后处理调度：串行、断点续跑、录音优先、电源策略
public final class PipelineRunner: @unchecked Sendable {
    private let jobs: JobRepository
    private let meetings: MeetingRepository
    private let steps: PipelineStepRunner
    private let power: PowerSource
    private let isRecording: @Sendable () -> Bool
    private let sleep: @Sendable (Duration) async -> Void

    private let lock = NSLock()
    private var wakeContinuation: AsyncStream<Void>.Continuation?
    private var loop: Task<Void, Never>?
    private var draining = false
    /// 正在处理的会议，及其当前步骤的任务（暂停时取消它）
    private var currentMeeting: UUID?
    private var currentStep: Task<Job, Error>?
    /// 用户要求暂停的会议
    private var pauseRequested: Set<UUID> = []

    /// 任务结束（成功或失败）时回调，用于系统通知
    public var onJobFinished: (@Sendable (Job) -> Void)?
    /// 进度变化（会议 id, 0–1），用于界面
    public var onProgress: (@Sendable (UUID, Double) -> Void)?

    public init(jobs: JobRepository, meetings: MeetingRepository, steps: PipelineStepRunner, power: PowerSource,
                isRecording: @escaping @Sendable () -> Bool,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.jobs = jobs
        self.meetings = meetings
        self.steps = steps
        self.power = power
        self.isRecording = isRecording
        self.sleep = sleep
    }

    /// 入队：用电池时进入 waitingForPower；已暂停的任务直接继续
    @discardableResult
    public func enqueue(meetingID: UUID, modelID: String) throws -> Job {
        var job = try jobs.enqueue(meetingID: meetingID, modelID: modelID,
                                   status: power.isOnAC ? .queued : .waitingForPower, at: Date())
        if job.status == .paused {
            job.status = .queued
            try jobs.update(job)
        }
        wake()
        return job
    }

    /// 暂停：正在跑的任务中断当前步骤（已完成的步骤保留），排队中的任务不再开始
    public func pause(meetingID: UUID) throws {
        let running = lock.withLock { () -> Bool in
            guard currentMeeting == meetingID else { return false }
            pauseRequested.insert(meetingID)
            currentStep?.cancel()
            return true
        }
        guard !running, var job = try jobs.job(for: meetingID),
              job.status == .queued || job.status == .waitingForPower else { return }
        job.status = .paused
        try jobs.update(job)
    }

    /// 继续已暂停的任务，从断点接着跑
    public func resume(meetingID: UUID) throws {
        guard var job = try jobs.job(for: meetingID), job.status == .paused else { return }
        job.status = .queued
        try jobs.update(job)
        wake()
    }

    /// 用户点"现在处理"
    public func processNow(meetingID: UUID) throws {
        guard var job = try jobs.job(for: meetingID), job.status == .waitingForPower else { return }
        job.status = .queued
        try jobs.update(job)
        wake()
    }

    /// 电源状态变化：插上电后放行等待中的任务
    public func powerChanged() throws {
        guard power.isOnAC else { return }
        for var job in try jobs.jobs(status: .waitingForPower) {
            job.status = .queued
            try jobs.update(job)
        }
        wake()
    }

    /// 启动时调用：上次退出时还在跑的任务改回排队
    public func recoverAfterLaunch() throws {
        try jobs.requeueStaleRunning()
    }

    /// 开始后台消费：有新任务或被唤醒时处理，处理完继续等待
    public func start() {
        let stream = AsyncStream<Void> { c in lock.withLock { wakeContinuation = c } }
        loop = Task.detached(priority: .utility) { [weak self] in
            await self?.drain()
            for await _ in stream {
                await self?.drain()
            }
        }
    }

    public func wake() {
        _ = lock.withLock { wakeContinuation?.yield() }
    }

    /// 处理完所有排队中的任务（测试直接调用）
    public func drain() async {
        let alreadyDraining = lock.withLock { () -> Bool in
            defer { draining = true }
            return draining
        }
        guard !alreadyDraining else { return }
        defer { lock.withLock { draining = false } }
        while let job = try? jobs.next() {
            await run(job)
        }
    }

    // MARK: - 内部

    private func run(_ initial: Job) async {
        var job = initial
        lock.withLock { currentMeeting = job.meetingID }
        defer { lock.withLock { currentMeeting = nil; currentStep = nil; pauseRequested.remove(initial.meetingID) } }
        job.status = .running
        job.error = nil
        try? jobs.update(job)
        try? meetings.updateStatus(job.meetingID, .processing)
        let all = JobStep.allCases
        report(job, Double(job.completedSteps.count) / Double(all.count))
        do {
            for step in all where !job.completedSteps.contains(step) {
                // 录音优先：录音期间不开始新步骤
                while isRecording() { await sleep(.seconds(2)) }
                let done = Double(job.completedSteps.count)
                let meetingID = job.meetingID
                let total = Double(all.count)
                let steps = steps, current = job
                let task = Task {
                    try await steps.run(step, job: current) { [weak self] p in
                        self?.onProgress?(meetingID, (done + min(max(p, 0), 1)) / total)
                    }
                }
                let paused = lock.withLock { () -> Bool in
                    currentStep = task
                    return pauseRequested.contains(meetingID)
                }
                if paused { task.cancel() }
                job = try await task.value
                job.completedSteps.append(step)
                job.interruptions = 0
                job.progress = Double(job.completedSteps.count) / total
                try jobs.update(job)
                report(job, job.progress)
            }
            job.status = .done
            job.progress = 1
            try jobs.update(job)
            try meetings.updateStatus(job.meetingID, .done)
        } catch where lock.withLock({ pauseRequested.contains(job.meetingID) }) {
            job.status = .paused
            try? jobs.update(job)
            try? meetings.updateStatus(job.meetingID, .pendingProcessing)
            // 不再回报进度：界面已在 pause() 时切到"已暂停"，再回报会被当成"转写中"
            return
        } catch {
            job.status = .failed
            job.error = error.localizedDescription
            try? jobs.update(job)
            try? meetings.updateStatus(job.meetingID, .failed)
        }
        onJobFinished?(job)
    }

    private func report(_ job: Job, _ p: Double) {
        onProgress?(job.meetingID, p)
    }
}

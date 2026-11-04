import Foundation
import MotingCapture
import MotingCore
import MotingStorage

public enum RecordingState: Sendable, Equatable {
    /// stopping：已确定结束时刻，正在停设备和收尾
    case idle, recording, paused, stopping, stopped
}

/// 一场录音：管理各路音频源、按会议时钟对齐写盘、记录暂停与标记。
/// 所有状态只在内部串行队列上读写。
public final class RecordingSession: @unchecked Sendable {
    private let paths: AppPaths
    private let repository: MeetingRepository
    private let sources: [AudioSource]
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "moting.recording.session", qos: .userInitiated)
    private let aligner = TrackAligner()

    private var clock = MeetingClock()
    private var writers: [AudioChannel: PCMTrackWriter] = [:]
    private var syncTimer: DispatchSourceTimer?
    private var _state: RecordingState = .idle
    private var _meeting: Meeting?
    /// 用户点结束的时刻；停设备可能耗时数秒，这之后到达的数据丢弃
    private var stopAt: Date?
    private var stateBeforeStop: RecordingState = .recording

    /// 给 UI 电平和后续实时识别订阅，在内部队列上回调
    public var onEvent: (@Sendable (AudioChannel, AudioSourceEvent) -> Void)?

    /// 每次真实音频写入轨道后在会话队列上回调：采样（不含补的静音）与它在轨道中的起始位置。
    /// startSample / 16000 即会议时间，与录音文件严格对齐
    public var onTrackAudio: (@Sendable (AudioChannel, [Float], _ startSample: Int) -> Void)?

    public init(paths: AppPaths, repository: MeetingRepository,
                sources: [AudioSource], now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        self.repository = repository
        self.sources = sources
        self.now = now
    }

    public var state: RecordingState { queue.sync { _state } }
    public var meeting: Meeting? { queue.sync { _meeting } }

    public func start() throws -> Meeting {
        let m = try prepare()
        var started: [AudioSource] = []
        do {
            for s in sources {
                let channel = s.channel
                try s.start { [weak self] event in
                    // 在收到事件时取时间，而不是排队处理时，避免队列延迟影响对齐
                    guard let self else { return }
                    let at = self.now()
                    self.queue.async { self.handle(channel, event, at: at) }
                }
                started.append(s)
            }
        } catch {
            started.forEach { $0.stop() }
            queue.sync {
                _state = .stopped
                closeWriters()
                try? repository.setStatus(m.id, .failed, endedAt: now())
            }
            throw error
        }
        queue.sync { startSyncTimer() }
        return m
    }

    /// 建目录、插入会议、打开写入器、启动时钟
    private func prepare() throws -> Meeting {
        try queue.sync {
            guard _state == .idle else { throw RecordingError.alreadyStarted }
            let m = Meeting.new(startedAt: now())
            _meeting = m
            try paths.ensureMeetingDirectory(m.id)
            let tracks = sources.map {
                AudioTrackInfo(meetingID: m.id, channel: $0.channel,
                               relativePath: paths.relativeTrackPath(m.id, $0.channel), sampleRate: 16_000)
            }
            try repository.insert(m, tracks: tracks)
            for s in sources {
                writers[s.channel] = try PCMTrackWriter(url: paths.trackURL(m.id, s.channel))
            }
            clock.start(at: now())
            _state = .recording
            return m
        }
    }

    public func pause() throws {
        try queue.sync {
            guard _state == .recording, let m = _meeting else { return }
            clock.pause(at: now())
            try repository.beginPause(meetingID: m.id, at: now())
            _state = .paused
        }
    }

    public func resume() throws {
        try queue.sync {
            guard _state == .paused, let m = _meeting else { return }
            clock.resume(at: now())
            try repository.endOpenPause(meetingID: m.id, at: now())
            _state = .recording
        }
    }

    public func addMark() throws -> Mark {
        try queue.sync {
            guard let m = _meeting, _state == .recording || _state == .paused else { throw RecordingError.notRecording }
            let mark = Mark(meetingID: m.id, at: clock.elapsed(at: now()))
            try repository.addMark(mark)
            return mark
        }
    }

    /// 幂等：先定下结束时刻 → 停源（可能耗时数秒）→ 处理完结束时刻前的数据 → 补齐两路长度 → 落盘 → 状态改为待处理
    public func stop() throws {
        let begun: Bool = queue.sync {
            guard _state == .recording || _state == .paused else { return false }
            stopAt = now()
            stateBeforeStop = _state
            _state = .stopping
            return true
        }
        guard begun else { return }
        sources.forEach { $0.stop() }
        try queue.sync {
            guard _state == .stopping, let m = _meeting, let end = stopAt else { return }
            syncTimer?.cancel()
            syncTimer = nil
            if stateBeforeStop == .paused {
                try repository.endOpenPause(meetingID: m.id, at: end)
            }
            let elapsed = clock.elapsed(at: end)
            clock.pause(at: end)
            for w in writers.values {
                try? w.appendSilence(max(0, aligner.adjustment(expectedElapsed: elapsed, written: w.sampleCount, incoming: 0)))
            }
            closeWriters()
            _state = .stopped
            try repository.setStatus(m.id, .pendingProcessing, endedAt: end)
        }
    }

    public func elapsed() -> TimeInterval {
        queue.sync { clock.elapsed(at: now()) }
    }

    /// 测试用：等待已排队的音频事件处理完
    func waitForPendingWrites() {
        queue.sync {}
    }

    // MARK: - 内部，均在 queue 上执行

    private func handle(_ channel: AudioChannel, _ event: AudioSourceEvent, at: Date) {
        onEvent?(channel, event)
        guard case .chunk(let chunk) = event, let w = writers[channel] else { return }
        // 结束过程中只收结束时刻之前采到的数据（且结束前处于录音而非暂停）
        let accepting = _state == .recording
            || (_state == .stopping && stateBeforeStop == .recording && at <= (stopAt ?? at))
        guard accepting else { return }
        let captured = at.addingTimeInterval(-chunk.pendingLatency)
        let adjust = aligner.adjustment(expectedElapsed: clock.elapsed(at: captured),
                                        written: w.sampleCount, incoming: chunk.samples.count)
        do {
            let samples: [Float]
            if adjust > 0 {
                try w.appendSilence(adjust)
                samples = chunk.samples
            } else {
                // 超前（设备时钟偏快等）：丢掉开头多出的部分
                samples = Array(chunk.samples.dropFirst(-adjust))
            }
            guard !samples.isEmpty else { return }
            let start = w.sampleCount
            try w.append(samples)
            onTrackAudio?(channel, samples, start)
        } catch {
            onEvent?(channel, .interrupted(L("写盘失败：\(String(describing: error))")))
        }
    }

    private func startSyncTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            self?.writers.values.forEach { try? $0.sync() }
        }
        t.resume()
        syncTimer = t
    }

    private func closeWriters() {
        writers.values.forEach { try? $0.close() }
        writers.removeAll()
    }
}

public enum RecordingError: Error {
    case alreadyStarted
    case notRecording
}

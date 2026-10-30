import Foundation
import MotingCapture
import MotingCore
import MotingStorage

public enum RecordingState: Sendable, Equatable {
    case idle, recording, paused, stopped
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

    /// 给 UI 电平和后续实时识别订阅，在内部队列上回调
    public var onEvent: (@Sendable (AudioChannel, AudioSourceEvent) -> Void)?

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

    /// 幂等：停源 → 处理完已排队的数据 → 补齐两路长度 → 落盘 → 状态改为待处理
    public func stop() throws {
        let active = queue.sync { _state == .recording || _state == .paused }
        guard active else { return }
        sources.forEach { $0.stop() }
        try queue.sync {
            guard _state == .recording || _state == .paused, let m = _meeting else { return }
            syncTimer?.cancel()
            syncTimer = nil
            let end = now()
            if _state == .paused {
                try repository.endOpenPause(meetingID: m.id, at: end)
            } else {
                clock.pause(at: end)
            }
            let elapsed = clock.elapsed(at: end)
            for w in writers.values {
                try? w.appendSilence(aligner.silenceToInsert(expectedElapsed: elapsed, written: w.sampleCount, incoming: 0))
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
        guard case .chunk(let chunk) = event, _state == .recording, let w = writers[channel] else { return }
        let pad = aligner.silenceToInsert(expectedElapsed: clock.elapsed(at: at),
                                          written: w.sampleCount, incoming: chunk.samples.count)
        do {
            try w.appendSilence(pad)
            try w.append(chunk.samples)
        } catch {
            onEvent?(channel, .interrupted("写盘失败：\(error)"))
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

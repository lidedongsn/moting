import AppKit
import Foundation
import MotingCapture
import MotingCore
import MotingRecording
import MotingStorage

/// 音频队列写、UI 定时读的电平与健康状态缓存，避免每个音频块都切到主线程
private final class MonitorBox: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt = Date()
    private var levels: [AudioChannel: Float] = [:]
    /// 上次取电平以来的峰值，刷新间隔里的短促音节也能显示出来
    private var peaks: [AudioChannel: Float] = [:]
    private var health: [AudioChannel: ChannelHealth] = [:]

    func record(_ ch: AudioChannel, _ event: AudioSourceEvent) {
        lock.withLock {
            if case .chunk(let c) = event {
                levels[ch] = c.level
                peaks[ch] = max(peaks[ch] ?? 0, c.level)
            }
            health[ch, default: ChannelHealth()].record(event, at: Date().timeIntervalSince(startedAt))
        }
    }

    func snapshot() -> (levels: [AudioChannel: Float], statuses: [AudioChannel: ChannelStatus]) {
        lock.withLock {
            let t = Date().timeIntervalSince(startedAt)
            var statuses: [AudioChannel: ChannelStatus] = [:]
            for ch in AudioChannel.allCases {
                statuses[ch] = (health[ch] ?? ChannelHealth()).status(at: t)
            }
            return (levels, statuses)
        }
    }

    /// 取出并清零各路峰值；这段时间没来数据的那一路沿用最近一块的电平
    func takePeaks() -> [AudioChannel: Float] {
        lock.withLock {
            var out = levels
            for (ch, p) in peaks { out[ch] = p }
            peaks = [:]
            return out
        }
    }
}

/// 两路电平单独发布、刷新得快，只让电平小视图跟着重绘，不牵动整个悬浮窗
@MainActor
final class LevelMeter: ObservableObject {
    @Published private(set) var levels: [AudioChannel: Float] = [:]

    func update(_ levels: [AudioChannel: Float]) {
        if levels != self.levels { self.levels = levels }
    }
}

@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    let meter = LevelMeter()
    /// 每一路的健康状态；非 .ok 时界面显示警告
    @Published private(set) var statuses: [AudioChannel: ChannelStatus] = [:]
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published var lastError: String?

    #if DEBUG
    /// 演示录音状态：界面和录音时一样，但不碰麦克风
    func showDemoRecording(paused: Bool) {
        state = paused ? .paused : .recording
        elapsed = 754
        meter.update([.mic: 0.08, .system: 0.03])
    }

    func showDemoStopped() { state = .stopped }
    #endif

    private let env: AppEnvironment?
    let live: LiveTranscriptModel
    let processing: ProcessingModel
    private var session: RecordingSession?
    private var ticker: Timer?
    private var levelTicker: Timer?
    private var monitor = MonitorBox()

    init(env: AppEnvironment?) {
        self.env = env
        live = LiveTranscriptModel(env: env)
        processing = ProcessingModel(env: env)
        // ⌘Q 等方式退出时先正常结束录音，避免会议停在"录音中"
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopSynchronously() }
        }
    }

    /// 标题：日历里正在开的会议优先（设置里打开时）；否则从检测到的通话开始时用软件名，
    /// 如"腾讯会议 2026-11-02 10:30"代替"会议 …"
    func start(source: String? = nil) {
        guard let env, session == nil || state == .stopped, !isStarting else { return }
        isStarting = true
        monitor = MonitorBox()
        let paths = env.paths, repository = env.repository, box = monitor, feeder = live.feeder
        Task.detached {
            // start() 可能同步等待麦克风授权弹窗，放到后台线程
            let session = RecordingSession(paths: paths, repository: repository,
                                           sources: [MicPreference.source(), SystemAudioTapSource()])
            session.onEvent = { ch, event in box.record(ch, event) }
            session.onTrackAudio = { ch, samples, start in feeder.value?.feed(ch, samples, startSample: start) }
            do {
                let meeting = try session.start()
                if let event = CalendarNaming.currentTitle() {
                    try? repository.rename(meeting.id, to: event)
                } else if let source, let title = Meeting.retitle(meeting.title, source: source) {
                    try? repository.rename(meeting.id, to: title)
                }
                await self.didStart(session, meetingID: meeting.id)
            } catch {
                await self.fail(error)
            }
        }
    }

    func pause() { perform { try $0.pause() } }
    func resume() { perform { try $0.resume() } }
    func mark() { perform { _ = try $0.addMark() } }

    /// 停止设备、销毁聚合设备、写盘可能要好几秒，放到后台，界面先显示"正在结束…"
    func stop() {
        guard let session, !isStopping, state == .recording || state == .paused else { return }
        isStopping = true
        ticker?.invalidate()
        ticker = nil
        levelTicker?.invalidate()
        levelTicker = nil
        Task.detached {
            let error: Error?
            do { try session.stop(); error = nil } catch let e { error = e }
            await self.didStop(error)
        }
    }

    /// 仅用于 app 退出：此时必须等收尾完成
    private func stopSynchronously() {
        guard let session else { return }
        try? session.stop()
        live.endAndWait()
    }

    /// 不到这么长（不算暂停）的录音视为误触，结束后直接丢弃
    static let minimumDuration: TimeInterval = 10

    private func didStop(_ error: Error?) {
        isStopping = false
        let duration = session?.elapsed() ?? 0
        let id = session?.meeting?.id
        if error == nil, let id, duration < Self.minimumDuration {
            // 先等实时字幕最后一句落库，再连同录音文件一起删掉，避免删完又写进来
            live.endAndWait()
            discard(id)
            processing.noteDiscarded(seconds: duration)
        } else {
            live.end()
        }
        processing.recordingChanged(false)
        // 正常结束的录音进入会后精准转写
        if error == nil, let id, duration >= Self.minimumDuration { processing.enqueueAfterRecording(id) }
        if let error { lastError = Self.describe(error) }
        refresh()
        meter.update([:])
        statuses = [:]
    }

    /// 删除一场会议的文件和记录（太短的录音）
    private func discard(_ id: UUID) {
        guard let env else { return }
        do {
            let dir = env.paths.meetingDirectory(id)
            if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
            if processing.selectedMeetingID == id { processing.selectedMeetingID = nil }
            try env.repository.delete(id)
        } catch {
            NSLog("丢弃过短录音失败：\(error)")
        }
    }

    private func didStart(_ s: RecordingSession, meetingID: UUID) {
        session = s
        live.begin(meetingID: meetingID)
        processing.recordingChanged(true)
        isStarting = false
        refresh()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        levelTicker = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { self?.meter.update([:]); return }
                self.meter.update(self.monitor.takePeaks())
            }
        }
    }

    private func fail(_ error: Error) {
        isStarting = false
        lastError = Self.describe(error)
    }

    private func perform(_ action: (RecordingSession) throws -> Void) {
        guard let session else { return }
        do {
            try action(session)
        } catch {
            lastError = Self.describe(error)
        }
        refresh()
    }

    private func refresh() {
        guard let session else { return }
        state = session.state
        elapsed = session.elapsed()
        guard state == .recording || state == .paused else { return }
        statuses = monitor.snapshot().statuses
    }

    /// 当前需要提醒用户的问题，没有则为空
    var warnings: [String] {
        AudioChannel.allCases.compactMap { ch in
            let who = ch == .mic ? L("麦克风（我）") : L("系统音频（对方）")
            switch statuses[ch] ?? .ok {
            case .ok:
                return nil
            case .interrupted(let reason):
                return L("\(who)已中断：\(reason)")
            case .stalled:
                return L("\(who)超过 3 秒没有收到音频数据")
            case .silent where ch == .system:
                return L("对方一直没有声音。如果会议里有人在说话，请到 系统设置 → 隐私与安全性 → 屏幕与系统录音 → 仅系统音频录制 中允许 Moting")
            case .silent:
                return L("麦克风一直没有声音，请检查麦克风是否被静音或权限是否被关闭")
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case CaptureError.permissionDenied(.mic):
            return L("没有麦克风权限。请到 系统设置 → 隐私与安全性 → 麦克风 中允许 Moting。")
        case CaptureError.permissionDenied(.system):
            return L("没有系统音频录制权限。请到 系统设置 → 隐私与安全性 → 屏幕与系统录音 → 仅系统音频录制 中允许 Moting。")
        case CaptureError.deviceUnavailable(let what):
            return L("音频设备不可用：\(what)")
        default:
            return L("录音出错：\(error.localizedDescription)")
        }
    }
}

extension TimeInterval {
    /// 00:00:00 形式
    var clockText: String {
        let s = Int(self)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

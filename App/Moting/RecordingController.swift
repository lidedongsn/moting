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
    private var health: [AudioChannel: ChannelHealth] = [:]

    func record(_ ch: AudioChannel, _ event: AudioSourceEvent) {
        lock.withLock {
            if case .chunk(let c) = event { levels[ch] = c.level }
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
}

@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levels: [AudioChannel: Float] = [:]
    /// 每一路的健康状态；非 .ok 时界面显示警告
    @Published private(set) var statuses: [AudioChannel: ChannelStatus] = [:]
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published var lastError: String?

    private let env: AppEnvironment?
    let live: LiveTranscriptModel
    private var session: RecordingSession?
    private var ticker: Timer?
    private var monitor = MonitorBox()

    init(env: AppEnvironment?) {
        self.env = env
        live = LiveTranscriptModel(env: env)
        // ⌘Q 等方式退出时先正常结束录音，避免会议停在"录音中"
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopSynchronously() }
        }
    }

    func start() {
        guard let env, session == nil || state == .stopped, !isStarting else { return }
        isStarting = true
        monitor = MonitorBox()
        let paths = env.paths, repository = env.repository, box = monitor, feeder = live.feeder
        Task.detached {
            // start() 可能同步等待麦克风授权弹窗，放到后台线程
            let session = RecordingSession(paths: paths, repository: repository,
                                           sources: [MicSource(), SystemAudioTapSource()])
            session.onEvent = { ch, event in box.record(ch, event) }
            session.onTrackAudio = { ch, samples, start in feeder.value?.feed(ch, samples, startSample: start) }
            do {
                let meeting = try session.start()
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

    private func didStop(_ error: Error?) {
        isStopping = false
        live.end()
        if let error { lastError = Self.describe(error) }
        refresh()
        levels = [:]
        statuses = [:]
    }

    private func didStart(_ s: RecordingSession, meetingID: UUID) {
        session = s
        live.begin(meetingID: meetingID)
        isStarting = false
        refresh()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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
        (levels, statuses) = monitor.snapshot()
    }

    /// 当前需要提醒用户的问题，没有则为空
    var warnings: [String] {
        AudioChannel.allCases.compactMap { ch in
            let who = ch == .mic ? "麦克风（我）" : "系统音频（对方）"
            switch statuses[ch] ?? .ok {
            case .ok:
                return nil
            case .interrupted(let reason):
                return "\(who)已中断：\(reason)"
            case .stalled:
                return "\(who)超过 3 秒没有收到音频数据"
            case .silent where ch == .system:
                return "对方一直没有声音。如果会议里有人在说话，请到 系统设置 → 隐私与安全性 → 屏幕与系统录音 → 仅系统音频录制 中允许 Moting"
            case .silent:
                return "麦克风一直没有声音，请检查麦克风是否被静音或权限是否被关闭"
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case CaptureError.permissionDenied(.mic):
            return "没有麦克风权限。请到 系统设置 → 隐私与安全性 → 麦克风 中允许 Moting。"
        case CaptureError.permissionDenied(.system):
            return "没有系统音频录制权限。请到 系统设置 → 隐私与安全性 → 屏幕与系统录音 → 仅系统音频录制 中允许 Moting。"
        case CaptureError.deviceUnavailable(let what):
            return "音频设备不可用：\(what)"
        default:
            return "录音出错：\(error.localizedDescription)"
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

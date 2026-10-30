import AppKit
import Foundation
import MotingCapture
import MotingCore
import MotingRecording
import MotingStorage

/// 音频队列写、UI 定时读的电平缓存，避免每个音频块都切到主线程
private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var levels: [AudioChannel: Float] = [:]
    func set(_ ch: AudioChannel, _ v: Float) { lock.withLock { levels[ch] = v } }
    func get() -> [AudioChannel: Float] { lock.withLock { levels } }
}

@MainActor
final class RecordingController: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var levels: [AudioChannel: Float] = [:]
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published var lastError: String?

    private let env: AppEnvironment?
    private var session: RecordingSession?
    private var ticker: Timer?
    private let levelBox = LevelBox()

    init(env: AppEnvironment?) {
        self.env = env
        // ⌘Q 等方式退出时先正常结束录音，避免会议停在"录音中"
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopSynchronously() }
        }
    }

    func start() {
        guard let env, session == nil || state == .stopped, !isStarting else { return }
        isStarting = true
        let paths = env.paths, repository = env.repository, box = levelBox
        Task.detached {
            // start() 可能同步等待麦克风授权弹窗，放到后台线程
            let session = RecordingSession(paths: paths, repository: repository,
                                           sources: [MicSource(), SystemAudioTapSource()])
            session.onEvent = { ch, event in
                if case .chunk(let c) = event { box.set(ch, c.level) }
            }
            do {
                _ = try session.start()
                await self.didStart(session)
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
    }

    private func didStop(_ error: Error?) {
        isStopping = false
        if let error { lastError = Self.describe(error) }
        refresh()
        levels = [:]
    }

    private func didStart(_ s: RecordingSession) {
        session = s
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
        levels = levelBox.get()
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

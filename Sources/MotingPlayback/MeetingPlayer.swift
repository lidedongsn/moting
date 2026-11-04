import AVFoundation
import Combine
import MotingCapture
import MotingCore
import MotingObjCSupport

/// 会议录音回放：把"我""对方"两路实时混音播放，按需分段读取文件。
/// 本进程的声音不会被系统音频 Tap 录进去（Tap 排除了本进程）
@MainActor
public final class MeetingPlayer: ObservableObject {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: TimeInterval = 0
    /// 无法播放的原因（例如输出设备正在切换、引擎没有运行），界面显示给用户；下次成功播放时清空
    @Published public private(set) var lastError: String?
    public let duration: TimeInterval
    /// 播放速度（变速不变调）
    public var rate: Float = 1 {
        didSet { timePitch.rate = rate }
    }
    /// 跳过静音：长于半秒的静音只留半秒停顿
    public var skipSilence = false {
        didSet {
            guard oldValue != skipSilence else { return }
            // 已排的缓冲按旧设置排的：从当前位置重排
            seek(to: currentTime)
        }
    }

    private static let rate = 16_000.0
    private static let chunk = 8_000            // 每个缓冲 0.5 秒
    private static let ahead = 4                // 预排 2 秒

    private let reader: PCMMixReader?
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    /// 已排缓冲：播放器走过的采样 → 录音里的位置（跳过静音后两者不再一一对应）
    private var map = PlaybackMap()
    private var lastChunkSilent = false
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var nextFrame = 0                   // 下一个要排进去的采样
    private var queued = 0
    private var generation = 0                  // seek / 停止后作废旧回调
    private var ticker: Timer?
    // 只在 init 写入、deinit 读取
    nonisolated(unsafe) private var configObserver: NSObjectProtocol?

    /// volume 仅供测试静音播放
    public init(urls: [URL], volume: Float = 1) {
        reader = try? PCMMixReader(urls: urls)
        duration = Double(reader?.frameCount ?? 0) / Self.rate
        engine.attach(node)
        engine.attach(timePitch)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        node.volume = volume
        // 输出设备切换（插拔耳机、蓝牙等）会让引擎停下：同步暂停，下次播放时重新排缓冲
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineStopped() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    public func toggle() {
        isPlaying ? pause() : play()
    }

    public func play() {
        guard reader != nil, duration > 0 else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        // engine.start 抛 Swift 错误；node.play 在引擎没有真正跑起来时抛 Objective-C 异常
        //（"player did not see an IO cycle"），Swift 接不住，必须经 MOTryCatch
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            fail(L("音频输出没有启动：\(error.localizedDescription)"))
            return
        }
        guard engine.isRunning else {
            fail(L("音频输出没有启动"))
            return
        }
        if queued == 0 { restart(at: Int(currentTime * Self.rate)) }
        if let reason = MOTryCatch({ node.play() }) {
            fail(reason)
            return
        }
        lastError = nil
        isPlaying = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    public func pause() {
        tick()
        node.pause()
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    public func seek(to t: TimeInterval) {
        let target = max(0, min(t, duration))
        currentTime = target
        restart(at: Int(target * Self.rate))
        if isPlaying, let reason = MOTryCatch({ node.play() }) { fail(reason) }
    }

    public func close() {
        pause()
        generation += 1
        node.stop()
        engine.stop()
    }

    // MARK: - 内部

    private func fail(_ reason: String) {
        lastError = L("无法播放：\(reason)。请稍后再试。")
        engineStopped()
    }

    /// 引擎已停或无法播放：回到暂停状态，作废已排的缓冲，下次播放从当前位置重排
    private func engineStopped() {
        tick()
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
        generation += 1
        node.stop()
        queued = 0
    }

    private func restart(at frame: Int) {
        generation += 1
        node.stop()
        queued = 0
        nextFrame = frame
        map = PlaybackMap()
        lastChunkSilent = false
        fill()
    }

    private func fill() {
        guard let reader else { return }
        while queued < Self.ahead, nextFrame < reader.frameCount {
            guard let samples = try? reader.read(at: nextFrame, count: Self.chunk), !samples.isEmpty,
                  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            // 跳过静音：连续静音块只保留第一块（半秒停顿），其余不排
            let silent = skipSilence && Self.isSilent(samples)
            defer { lastChunkSilent = silent }
            if silent && lastChunkSilent {
                nextFrame += samples.count
                continue
            }
            map.scheduled(source: nextFrame, count: samples.count)
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            nextFrame += samples.count
            queued += 1
            let gen = generation
            // 回调由 AVAudioPlayerNode 在它自己的队列上调用：必须显式标成 @Sendable（非主线程隔离），
            // 否则会被推断为 @MainActor，运行时隔离检查直接崩溃
            node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
                Task { @MainActor in self?.bufferDone(gen) }
            }
        }
    }

    private func bufferDone(_ gen: Int) {
        guard gen == generation else { return }
        queued -= 1
        fill()
        if queued == 0, nextFrame >= (reader?.frameCount ?? 0) {
            // 播放到结尾
            isPlaying = false
            ticker?.invalidate()
            ticker = nil
            currentTime = duration
        }
    }

    private func tick() {
        // 引擎没在输出时 lastRenderTime 可能无效，playerTime 会抛 Objective-C 异常（曾导致崩溃）
        guard let t = node.lastRenderTime, t.isSampleTimeValid || t.isHostTimeValid else { return }
        var sample: AVAudioFramePosition?
        _ = MOTryCatch { sample = node.playerTime(forNodeTime: t)?.sampleTime }
        guard let sample else { return }
        currentTime = min(duration, Double(map.source(forPlayed: Int(sample))) / Self.rate)
    }

    /// 半秒块的均方根低于约 -42dBFS 视为静音
    nonisolated static func isSilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        let ms = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        return ms < 0.008 * 0.008
    }
}

/// 播放器已走过的采样数 → 录音里的采样位置
struct PlaybackMap {
    private var entries: [(played: Int, source: Int, count: Int)] = []
    private var total = 0

    mutating func scheduled(source: Int, count: Int) {
        entries.append((total, source, count))
        total += count
    }

    func source(forPlayed p: Int) -> Int {
        guard let e = entries.last(where: { $0.played <= p }) else { return entries.first?.source ?? 0 }
        return e.source + min(p - e.played, e.count)
    }
}

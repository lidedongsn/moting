import AVFoundation
import MotingCapture

/// 会议录音回放：把"我""对方"两路实时混音播放，按需分段读取文件。
/// 本进程的声音不会被系统音频 Tap 录进去（Tap 排除了本进程）
@MainActor
final class MeetingPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    let duration: TimeInterval

    private static let rate = 16_000.0
    private static let chunk = 8_000            // 每个缓冲 0.5 秒
    private static let ahead = 4                // 预排 2 秒

    private let reader: PCMMixReader?
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var startFrame = 0                  // 本轮播放的起点
    private var nextFrame = 0                   // 下一个要排进去的采样
    private var queued = 0
    private var generation = 0                  // seek / 停止后作废旧回调
    private var ticker: Timer?

    init(urls: [URL]) {
        reader = try? PCMMixReader(urls: urls)
        duration = Double(reader?.frameCount ?? 0) / Self.rate
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard reader != nil, duration > 0 else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }
        if queued == 0 { restart(at: Int(currentTime * Self.rate)) }
        node.play()
        isPlaying = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        tick()
        node.pause()
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    func seek(to t: TimeInterval) {
        let target = max(0, min(t, duration))
        currentTime = target
        restart(at: Int(target * Self.rate))
        if isPlaying { node.play() }
    }

    func close() {
        pause()
        generation += 1
        node.stop()
        engine.stop()
    }

    // MARK: - 内部

    private func restart(at frame: Int) {
        generation += 1
        node.stop()
        queued = 0
        startFrame = frame
        nextFrame = frame
        fill()
    }

    private func fill() {
        guard let reader else { return }
        while queued < Self.ahead, nextFrame < reader.frameCount {
            guard let samples = try? reader.read(at: nextFrame, count: Self.chunk), !samples.isEmpty,
                  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            nextFrame += samples.count
            queued += 1
            let gen = generation
            node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
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
        guard let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t) else { return }
        currentTime = min(duration, Double(startFrame + Int(p.sampleTime)) / Self.rate)
    }
}

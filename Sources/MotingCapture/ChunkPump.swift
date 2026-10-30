import Foundation

/// 消费端：每 20ms 从环形缓冲取数据，重采样到 16kHz 后回调 .chunk。
/// 麦克风源与系统音频源共用。所有方法都必须在 queue 上调用。
final class ChunkPump {
    let queue: DispatchQueue
    let ring = SPSCRingBuffer(capacity: 1 << 18)   // 约 5 秒 48kHz，足够吸收消费端抖动
    private var resampler: Resampler?
    private var timer: DispatchSourceTimer?
    private var buffer = [Float](repeating: 0, count: 1 << 16)
    private var handler: (@Sendable (AudioSourceEvent) -> Void)?

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func start(inputSampleRate: Double, handler: @escaping @Sendable (AudioSourceEvent) -> Void) throws {
        self.handler = handler
        resampler = try Resampler(inputSampleRate: inputSampleRate)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        timer = t
    }

    /// 设备采样率变化或换设备时调用：先把旧数据按旧采样率处理完，再换重采样器
    func reconfigure(inputSampleRate: Double) throws {
        drain()
        if let tail = try resampler?.flush(), !tail.isEmpty { emit(tail) }
        resampler = try Resampler(inputSampleRate: inputSampleRate)
    }

    func send(_ event: AudioSourceEvent) {
        handler?(event)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        drain()
        if let tail = try? resampler?.flush(), !tail.isEmpty { emit(tail) }
        resampler = nil
        handler = nil
    }

    private func drain() {
        guard let resampler else { return }
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: $0.count) }
            guard n > 0 else { break }
            if let out = try? resampler.process(Array(buffer[0..<n])), !out.isEmpty { emit(out) }
        }
    }

    private func emit(_ samples: [Float]) {
        var sum: Float = 0
        for s in samples { sum += s * s }
        handler?(.chunk(AudioChunk(samples: samples, level: (sum / Float(samples.count)).squareRoot())))
    }
}

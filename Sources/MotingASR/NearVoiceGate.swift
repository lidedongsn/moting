import Foundation

/// 近场人声门限：只用于麦克风一路。
/// 按 20ms 帧计算电平，自动跟踪环境底噪与用户说话音量；明显低于用户音量的声音（远处的人、环境声）置零。
/// 输出与输入等长，整体延迟 lookahead（开头补零），以便在句首到来前就打开门限，不切掉第一个字
public struct NearVoiceGate: Sendable {
    private static let frame = 320                 // 20ms @16kHz
    private static let marginOverFloor = 10.0      // 至少高出底噪 10dB
    private static let marginBelowSpeech = 12.0    // 比用户音量低 12dB 以上视为远处
    private static let floorRisePerFrame = 0.01    // 底噪每帧最多上升 0.01dB（约 0.5dB/秒）

    private let lookaheadFrames: Int
    private let hangoverFrames: Int
    private let delay: Int

    private var delayLine: [Float]
    private var pending: [Float] = []
    /// 已完成帧的"近场"标记，flagsBase 为 flags[0] 对应的帧序号
    private var flags: [Bool] = []
    private var flagsBase = 0
    private var outputIndex = 0                    // 下一个输出采样在输入时间轴上的位置（可能为负，表示开头补的零）
    private var floor: Double?
    private var speechLevel = -30.0

    public init(lookahead: TimeInterval = 0.2, hangover: TimeInterval = 0.3) {
        lookaheadFrames = Int(lookahead * 16_000) / Self.frame
        hangoverFrames = Int(hangover * 16_000) / Self.frame
        delay = lookaheadFrames * Self.frame
        delayLine = [Float](repeating: 0, count: delay)
        outputIndex = -delay
    }

    public mutating func process(_ samples: [Float]) -> [Float] {
        analyze(samples)
        delayLine += samples
        let n = samples.count
        var out = Array(delayLine.prefix(n))
        delayLine.removeFirst(n)
        for i in 0..<n where !keeps(sampleAt: outputIndex + i) {
            out[i] = 0
        }
        outputIndex += n
        trimFlags()
        return out
    }

    // MARK: - 内部

    private mutating func analyze(_ samples: [Float]) {
        pending += samples
        while pending.count >= Self.frame {
            var sum: Float = 0
            for i in 0..<Self.frame { sum += pending[i] * pending[i] }
            pending.removeFirst(Self.frame)
            let db = 10 * log10(Double(sum / Float(Self.frame)) + 1e-12)
            let f = min(floor ?? db, db)
            floor = db > f ? f + Self.floorRisePerFrame : f
            let near = db >= max(f + Self.marginOverFloor, speechLevel - Self.marginBelowSpeech)
            if near { speechLevel = speechLevel * 0.95 + db * 0.05 }
            flags.append(near)
        }
    }

    /// 该采样所在帧的 [-hangover, +lookahead] 范围内是否有近场帧
    private func keeps(sampleAt index: Int) -> Bool {
        guard index >= 0 else { return false }
        let f = index / Self.frame
        let lo = max(f - hangoverFrames, flagsBase)
        let hi = min(f + lookaheadFrames, flagsBase + flags.count - 1)
        guard lo <= hi else { return false }
        for k in lo...hi where flags[k - flagsBase] { return true }
        return false
    }

    /// 只保留判断仍需要的帧标记，长时间录音时内存不增长
    private mutating func trimFlags() {
        let needed = max(0, outputIndex / Self.frame - hangoverFrames)
        let drop = min(max(0, needed - flagsBase), flags.count)
        if drop > 0 {
            flags.removeFirst(drop)
            flagsBase += drop
        }
    }
}

import Foundation

/// 按能量判断"我"一路的一句话是不是外放回声（会后用，补充按文字去重）。
/// 外放时麦克风会在几十毫秒后听到对方的声音，能量大致是系统音频的固定比例。
/// 先在整场会议上估出这个延迟和比例；再逐句看：有声的帧几乎都能用"延迟、衰减后的对方声音"解释，
/// 就是回声；明显比预测响的帧是自己在说话（双方同时说时也成立），这句保留。
/// 戴耳机时两路对不上，估不出模型，什么都不删。
public enum EnergyEcho {
    public static let sampleRate = 16_000
    /// 每帧 20ms
    public static let frame = 320
    public static var framesPerSecond: Double { Double(sampleRate) / Double(frame) }

    public struct Model: Equatable, Sendable {
        /// 麦克风比系统音频晚几帧
        public var lag: Int
        /// 回声能量 / 系统音频能量
        public var gain: Float
        /// 麦克风底噪能量
        public var micFloor: Float
    }

    /// 最多找 300ms 的延迟
    static let maxLag = 15
    /// 两路对数能量的相关性低于这个，认为麦克风里没有外放声
    static let minCorrelation: Float = 0.6
    /// 至少要有这么多帧对方在说话（5 秒）才估
    static let minActiveFrames = 250

    /// 每 20ms 的平均能量
    public static func frameEnergies(_ x: [Float]) -> [Float] {
        stride(from: 0, to: x.count - frame + 1, by: frame).map { s in
            var e: Float = 0
            for i in s..<(s + frame) { e += x[i] * x[i] }
            return e / Float(frame)
        }
    }

    /// 从 16kHz 16 位 PCM 文件按块读，算每帧能量（长会议不必整段读进内存）
    public static func frameEnergies(pcmFile url: URL) throws -> [Float] {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var out: [Float] = []
        let bytesPerFrame = frame * 2
        while let data = try h.read(upToCount: bytesPerFrame * 500), data.count >= bytesPerFrame {
            data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for f in 0..<(data.count / bytesPerFrame) {
                    var e: Float = 0
                    for i in (f * frame)..<((f + 1) * frame) {
                        let v = Float(Int16(littleEndian: p[i])) / Float(Int16.max)
                        e += v * v
                    }
                    out.append(e / Float(frame))
                }
            }
        }
        return out
    }

    /// 估计回声的延迟和比例；麦克风里听不出对方的声音时返回 nil
    public static func estimate(mic: [Float], system: [Float]) -> Model? {
        let n = min(mic.count, system.count)
        guard n > maxLag else { return nil }
        let loud = percentile(Array(system[0..<n]), 0.95)
        guard loud > 0 else { return nil }
        let threshold = loud * 0.05
        var best: (lag: Int, r: Float) = (0, -1)
        for lag in 0...maxLag {
            var xs: [Float] = [], ys: [Float] = []
            for i in lag..<n where system[i - lag] > threshold {
                xs.append(log10(system[i - lag] + 1e-10))
                ys.append(log10(mic[i] + 1e-10))
            }
            guard xs.count >= minActiveFrames else { return nil }
            let r = correlation(xs, ys)
            if r > best.r { best = (lag, r) }
        }
        guard best.r >= minCorrelation else { return nil }
        var ratios: [Float] = []
        for i in best.lag..<n where system[i - best.lag] > threshold {
            ratios.append(mic[i] / system[i - best.lag])
        }
        let nonzero = mic[0..<n].filter { $0 > 0 }
        let floor = max(percentile(nonzero, 0.1), 1e-9)
        return Model(lag: best.lag, gain: percentile(ratios, 0.5), micFloor: floor)
    }

    /// start / end 秒之间的这句是否只是回声
    public static func isBleed(start: Double, end: Double, mic: [Float], system: [Float], model: Model) -> Bool {
        let i0 = max(0, Int(start * framesPerSecond)), i1 = min(mic.count, Int(end * framesPerSecond))
        guard i1 > i0 else { return false }
        var voiced = 0, local = 0
        for i in i0..<i1 where mic[i] > model.micFloor * 8 {
            voiced += 1
            // 混响会把回声拖长一点：取前后一帧里最大的
            var ref: Float = 0
            for j in (i - model.lag - 1)...(i - model.lag + 1) where j >= 0 && j < system.count { ref = max(ref, system[j]) }
            if mic[i] > 4 * model.gain * ref + model.micFloor * 2 { local += 1 }
        }
        // 有声帧太少无从判断，保留
        guard voiced >= 10 else { return false }
        return Float(local) / Float(voiced) < 0.2
    }

    private static func percentile(_ x: [Float], _ p: Float) -> Float {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        return s[min(s.count - 1, Int(Float(s.count - 1) * p))]
    }

    private static func correlation(_ x: [Float], _ y: [Float]) -> Float {
        let n = Float(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
        for i in x.indices {
            let a = x[i] - mx, b = y[i] - my
            sxy += a * b; sxx += a * a; syy += b * b
        }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
    }
}

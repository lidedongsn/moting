import Foundation

/// 纯逻辑：根据"此刻应写到第几个采样"与"已写了多少"，决定补静音还是丢弃。
/// 落后或超前超过容差时才调整，保证两路轨道的第 N 个采样对应同一会议时刻。
public struct TrackAligner: Sendable {
    private let sampleRate: Int
    private let toleranceSamples: Int

    public init(sampleRate: Int = 16_000, tolerance: TimeInterval = 0.2) {
        self.sampleRate = sampleRate
        toleranceSamples = Int(tolerance * Double(sampleRate))
    }

    /// 正数：写入前补这么多静音；负数：从本次数据开头丢弃这么多采样（不超过 incoming）
    public func adjustment(expectedElapsed: TimeInterval, written: Int, incoming: Int) -> Int {
        let expected = Int(expectedElapsed * Double(sampleRate))
        let gap = expected - (written + incoming)
        if gap > toleranceSamples { return gap }
        if -gap > toleranceSamples { return -min(-gap, incoming) }
        return 0
    }
}

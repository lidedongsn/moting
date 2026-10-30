import Foundation

/// 纯逻辑：根据"此刻应写到第几个采样"与"已写了多少"，决定补多少静音。
/// 只补落后、不丢超前，保证两路轨道的第 N 个采样对应同一会议时刻。
public struct TrackAligner: Sendable {
    private let sampleRate: Int
    private let toleranceSamples: Int

    public init(sampleRate: Int = 16_000, tolerance: TimeInterval = 0.2) {
        self.sampleRate = sampleRate
        toleranceSamples = Int(tolerance * Double(sampleRate))
    }

    public func silenceToInsert(expectedElapsed: TimeInterval, written: Int, incoming: Int) -> Int {
        let expected = Int(expectedElapsed * Double(sampleRate))
        let gap = expected - (written + incoming)
        return gap > toleranceSamples ? gap : 0
    }
}

import Foundation

/// 一次发言：同一个人连续说的几句，转写稿按发言成段显示，读起来像对话而不是日志
public struct TranscriptTurn: Identifiable, Equatable, Sendable {
    public let speaker: SpeakerKey
    public let segments: [TranscriptSegment]
    public var id: UUID { segments[0].id }
    public var start: TimeInterval { segments[0].start }
    public var end: TimeInterval { segments[segments.count - 1].end }
}

public enum TranscriptTurns {
    /// 同一个人停顿超过这么久，算另一段
    public static let maxGap: TimeInterval = 20
    /// 一段最长这么久：点击一段从段首播放，太长就跳不准了
    public static let maxLength: TimeInterval = 60

    public static func group(_ segments: [TranscriptSegment]) -> [TranscriptTurn] {
        var turns: [[TranscriptSegment]] = []
        for s in segments.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let last = turns.last, let first = last.first, let tail = last.last,
               first.speakerKey == s.speakerKey, s.start - tail.end <= maxGap, s.start - first.start <= maxLength {
                turns[turns.count - 1].append(s)
            } else {
                turns.append([s])
            }
        }
        return turns.map { TranscriptTurn(speaker: $0[0].speakerKey, segments: $0) }
    }

    /// 播放位置所在的那段：turns 按时间排好序，二分找最后一个不晚于 t 开始的
    public static func index(in turns: [TranscriptTurn], at t: TimeInterval) -> Int? {
        var lo = 0, hi = turns.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if turns[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }
}

import Foundation

/// 说话人身份：我，或对方中的某个人（标签如"说话人 1"；未做分离时为"对方"）
public enum SpeakerKey: Hashable, Sendable {
    case me
    case other(String)
}

extension TranscriptSegment {
    public var speakerKey: SpeakerKey {
        channel == .mic ? .me : .other(speakerLabel ?? "对方")
    }
}

/// 给说话人编号，界面据此取颜色：0 = 我；其他人按在会议里首次出现的时间顺序编 1、2、3…
public enum SpeakerPalette {
    public static func indices(for segments: [TranscriptSegment]) -> [SpeakerKey: Int] {
        var result: [SpeakerKey: Int] = [.me: 0]
        for s in segments.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) where result[s.speakerKey] == nil {
            result[s.speakerKey] = result.count
        }
        return result
    }
}

/// 迷你声纹条：把会议切成 count 段，每段取说话时间最长的人；无人说话为 nil
public enum SpeakingTimeline {
    public static func bins(_ segments: [TranscriptSegment], duration: TimeInterval, count: Int) -> [SpeakerKey?] {
        guard count > 0 else { return [] }
        guard duration > 0, !segments.isEmpty else { return Array(repeating: nil, count: count) }
        let width = duration / Double(count)
        var talk = Array(repeating: [SpeakerKey: Double](), count: count)
        for s in segments where s.end > s.start {
            let first = max(0, Int(s.start / width)), last = min(count - 1, Int(s.end / width))
            guard first <= last else { continue }
            for b in first...last {
                let overlap = min(s.end, Double(b + 1) * width) - max(s.start, Double(b) * width)
                if overlap > 0 { talk[b][s.speakerKey, default: 0] += overlap }
            }
        }
        return talk.map { $0.max { $0.value < $1.value }?.key }
    }
}

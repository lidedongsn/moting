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

/// 一段发言拼成的文字，记着每句的位置：点到哪个字就知道是哪句。位置用 UTF-16，和 NSString / NSTextView 一致
public struct TurnText: Sendable {
    public let text: String
    public let ranges: [(segment: TranscriptSegment, range: NSRange)]

    public init(_ turn: TranscriptTurn) {
        var text = ""
        var ranges: [(TranscriptSegment, NSRange)] = []
        for s in turn.segments {
            // 英文句子之间要有空格，中文不要
            if let last = text.last, let first = s.text.first, last.isASCII, first.isASCII, !last.isWhitespace { text += " " }
            let location = (text as NSString).length
            text += s.text
            ranges.append((s, NSRange(location: location, length: (s.text as NSString).length)))
        }
        self.text = text
        self.ranges = ranges
    }

    /// 句子之间的空格算前一句；超出文字范围返回 nil
    public func segment(atCharacter index: Int) -> TranscriptSegment? {
        guard index >= 0, index < (text as NSString).length else { return nil }
        return ranges.last { $0.range.location <= index }?.segment
    }
}

extension TranscriptTurns {
    /// 点一句时从哪里开始播：精准稿时间准，只留一点余量；实时识别的句首偏晚，提前 1 秒避免切掉第一个字
    public static func playbackStart(of segment: TranscriptSegment, kind: TranscriptKind?) -> TimeInterval {
        max(0, segment.start - (kind == .final ? 0.2 : 1))
    }
}

/// 整段编辑后把文字对回各句：每句的时间不变，所以点句播放和高亮仍然准确
public enum TurnEdit {
    public struct Result: Equatable, Sendable {
        public var texts: [UUID: String] = [:]
        public var removed: [UUID] = []
    }

    /// runs：编辑器里按顺序的文字，带所属句子的标记；没有标记的（比如粘贴进来的）归到前一句，开头的归到第一句
    public static func changes(original: [TranscriptSegment], runs: [(id: UUID?, text: String)]) -> Result {
        var joined: [UUID: String] = [:]
        var last = original.first?.id
        for run in runs {
            guard let id = run.id ?? last else { continue }
            joined[id, default: ""] += run.text
            last = id
        }
        var result = Result()
        for s in original {
            let text = (joined[s.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                result.removed.append(s.id)
            } else if text != s.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                result.texts[s.id] = text
            }
        }
        return result
    }
}

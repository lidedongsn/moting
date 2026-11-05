import Foundation
import MotingASR

/// 说话人分离之后再合并一轮。分离是按短片段聚类的，短片段的声纹不稳定，
/// 会议软件压缩过的声音尤其容易把一个人切成好几个；把一个"人"的全部音频合起来，声纹就稳定了。
/// 实测（2026-11-05）：同一个人被切开时整体相似度 0.82–0.92，官方 4 人样本里不同的人最高 0.52
public enum SpeakerMerger {
    /// 整体声纹相似度到这个值算同一个人，取在两组实测值之间
    public static let sameSpeakerThreshold: Float = 0.7
    /// 总时长不到这个秒数，声纹不可信（实测同一个人的 1 秒片段相似度只有 0.3 左右），并入时间上最近的说话人
    public static let minSpeech: TimeInterval = 3

    /// 只改每段的归属，不改时间。embeddings：说话人 → 其全部音频的声纹；缺了就不参与合并
    public static func merge(_ turns: [SpeakerTurn], embeddings: [Int: [Float]]) -> [SpeakerTurn] {
        guard !turns.isEmpty else { return [] }
        var duration: [Int: TimeInterval] = [:]
        for t in turns { duration[t.speaker, default: 0] += t.end - t.start }
        let longEnough = duration.filter { $0.value >= minSpeech }.map(\.key)
        // 全都太短：没有可信的声纹，当成一个人
        guard !longEnough.isEmpty else {
            let main = duration.max { $0.value < $1.value }!.key
            return turns.map { SpeakerTurn(start: $0.start, end: $0.end, speaker: main) }
        }

        // 按平均声纹逐步合并，不用"像其中一个就算"，否则 A 像 B、B 像 C 会把 A 和 C 串在一起
        var groups: [(members: [Int], voice: [Float]?, weight: TimeInterval)] =
            longEnough.sorted().map { ([$0], embeddings[$0], duration[$0] ?? 0) }
        while let (i, j) = closestPair(groups) {
            let a = groups[i], b = groups[j]
            groups[i] = (a.members + b.members, average(a.voice!, a.weight, b.voice!, b.weight), a.weight + b.weight)
            groups.remove(at: j)
        }
        var target: [Int: Int] = [:]
        for g in groups {
            let main = g.members.max { (duration[$0] ?? 0) < (duration[$1] ?? 0) }!
            for m in g.members { target[m] = main }
        }

        let kept = turns.filter { target[$0.speaker] != nil }
        return turns.map { t in
            if let to = target[t.speaker] { return SpeakerTurn(start: t.start, end: t.end, speaker: to) }
            let nearest = kept.min { gap(t, $0) < gap(t, $1) }!
            return SpeakerTurn(start: t.start, end: t.end, speaker: target[nearest.speaker]!)
        }
    }

    private static func closestPair(_ groups: [(members: [Int], voice: [Float]?, weight: TimeInterval)]) -> (Int, Int)? {
        var best: (i: Int, j: Int, score: Float)?
        for i in groups.indices {
            for j in groups.indices where j > i {
                guard let a = groups[i].voice, let b = groups[j].voice else { continue }
                let score = VoiceprintMatcher.cosine(a, b)
                if score >= sameSpeakerThreshold, score > (best?.score ?? -1) { best = (i, j, score) }
            }
        }
        return best.map { ($0.i, $0.j) }
    }

    private static func average(_ a: [Float], _ wa: TimeInterval, _ b: [Float], _ wb: TimeInterval) -> [Float] {
        let total = Float(wa + wb)
        return zip(a, b).map { ($0 * Float(wa) + $1 * Float(wb)) / total }
    }

    /// 两段之间隔多久；重叠算 0
    static func gap(_ a: SpeakerTurn, _ b: SpeakerTurn) -> TimeInterval {
        max(0, max(a.start, b.start) - min(a.end, b.end))
    }
}

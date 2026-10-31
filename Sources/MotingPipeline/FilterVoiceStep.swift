import Foundation
import MotingASR
import MotingCapture
import MotingCore
import MotingStorage

public enum FilterOutcome: String, Codable, Sendable {
    /// 已按声纹删除旁人片段
    case filtered
    /// 用户还没登记声纹，没有过滤
    case skippedNoVoiceprint
    /// 过滤后剩下的太少，判定声纹不可靠，全部保留
    case fellBack
}

/// 声纹过滤："我"一路只保留与用户声纹匹配的片段，旁边与会议无关的人说话直接删除
public struct FilterVoiceStep {
    private let transcripts: TranscriptRepository

    public init(transcripts: TranscriptRepository) {
        self.transcripts = transcripts
    }

    public func run(versionID: UUID, micTrack: URL, voiceprint: URL?,
                    matcher: () throws -> VoiceprintMatching, progress: (Double) -> Void) throws -> FilterOutcome {
        guard let voiceprint, FileManager.default.fileExists(atPath: voiceprint.path) else { return .skippedNoVoiceprint }
        let me = try VoiceprintMatcher.load(voiceprint)
        let mic = try transcripts.segments(versionID: versionID).filter { $0.channel == .mic }
        guard !mic.isEmpty, FileManager.default.fileExists(atPath: micTrack.path) else { return .filtered }
        let reader = try PCMMixReader(urls: [micTrack])
        let m = try matcher()
        var drop: [UUID] = []
        var total = 0.0, kept = 0.0
        for (i, seg) in mic.enumerated() {
            try Task.checkCancellation()
            let start = Int(seg.start * 16_000)
            let samples = try reader.read(at: start, count: Int((seg.end - seg.start) * 16_000))
            let e = try m.embedding(samples)
            let duration = seg.end - seg.start
            total += duration
            // 太短提不出声纹的片段无法判断，保留
            if e.isEmpty || VoiceprintMatcher.cosine(e, me) >= VoiceprintPolicy.threshold {
                kept += duration
            } else {
                drop.append(seg.id)
            }
            progress(Double(i + 1) / Double(mic.count))
        }
        if total > 0, kept / total < VoiceprintPolicy.minKeptRatio { return .fellBack }
        try transcripts.deleteSegments(ids: drop)
        return .filtered
    }
}

/// 收尾：去掉外放回声造成的重复句，再把正式稿标记为完成，此后详情页才会显示它
public struct MergeStep {
    private let transcripts: TranscriptRepository

    public init(transcripts: TranscriptRepository) {
        self.transcripts = transcripts
    }

    public func run(versionID: UUID) throws {
        // 外放时"我"一路录进了对方的声音：删掉与"对方"同时同内容的句子
        let echo = EchoDedup.echoSegmentIDs(try transcripts.segments(versionID: versionID))
        if !echo.isEmpty { try transcripts.deleteSegments(ids: echo) }
        try transcripts.markCompleted(versionID, at: Date())
    }
}

/// 外放回声去重：会后精准转写时"我"一路会多出和"对方"同时、同内容的句子，按 EchoText 的规则删掉
public enum EchoDedup {
    public static func echoSegmentIDs(_ segments: [TranscriptSegment]) -> [UUID] {
        let system = segments.filter { $0.channel == .system }.sorted { $0.start < $1.start }
        return segments.filter { $0.channel == .mic }.compactMap { m in
            let theirs = system.filter { $0.start < m.end + EchoText.slack && $0.end > m.start - EchoText.slack }
                .map(\.text).joined()
            return EchoText.isEcho(m.text, of: theirs) ? m.id : nil
        }
    }
}

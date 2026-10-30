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

/// 收尾：把正式稿标记为完成，此后详情页才会显示它
public struct MergeStep {
    private let transcripts: TranscriptRepository

    public init(transcripts: TranscriptRepository) {
        self.transcripts = transcripts
    }

    public func run(versionID: UUID) throws {
        try transcripts.markCompleted(versionID, at: Date())
    }
}

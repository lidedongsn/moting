import Foundation
import MotingASR
import MotingCapture
import MotingCore
import MotingStorage

/// "对方"一路说话人分离：给正式稿里的系统音频片段打上"说话人 N"
public struct DiarizeStep {
    private let transcripts: TranscriptRepository
    private let diarizer: () throws -> Diarizing

    public init(transcripts: TranscriptRepository, diarizer: @escaping () throws -> Diarizing) {
        self.transcripts = transcripts
        self.diarizer = diarizer
    }

    /// N 从 1 起，按首次出现的顺序编号；一段的标签取与它时间重叠最长的分离结果
    public func run(versionID: UUID, systemTrack: URL, progress: (Double) -> Void) throws {
        let system = try transcripts.segments(versionID: versionID).filter { $0.channel == .system }
        guard !system.isEmpty, FileManager.default.fileExists(atPath: systemTrack.path) else {
            progress(1)
            return
        }
        progress(0)
        // 整路载入：2 小时约 460MB，可接受（见计划）
        let samples = try PCMTrackReader.readAll(systemTrack)
        let turns = try diarizer().diarize(samples)
        progress(0.9)
        guard !turns.isEmpty else {
            progress(1)
            return
        }
        var names: [Int: String] = [:]
        for t in turns.sorted(by: { $0.start < $1.start }) where names[t.speaker] == nil {
            names[t.speaker] = "说话人 \(names.count + 1)"
        }
        for seg in system {
            var best: (speaker: Int, overlap: Double)?
            for t in turns {
                let overlap = min(seg.end, t.end) - max(seg.start, t.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (t.speaker, overlap) }
            }
            if let best, let name = names[best.speaker] {
                try transcripts.setSpeakerLabel(seg.id, label: name)
            }
        }
        progress(1)
    }
}

import Foundation
import MotingASR
import MotingCapture
import MotingCore
import MotingStorage

/// "对方"一路说话人分离：给正式稿里的系统音频片段打上"说话人 N"
public struct DiarizeStep {
    private let transcripts: TranscriptRepository
    private let speakers: SpeakerRepository?
    private let diarizer: () throws -> Diarizing
    /// 算一段音频的声纹，用来把切碎的同一个人合并；不给就只并太短的
    private let embedder: (([Float]) throws -> [Float])?

    /// speakers：给了就在重新编号时清掉这场会议的旧改名
    public init(transcripts: TranscriptRepository, speakers: SpeakerRepository? = nil, diarizer: @escaping () throws -> Diarizing,
                embedder: (([Float]) throws -> [Float])? = nil) {
        self.embedder = embedder
        self.transcripts = transcripts
        self.speakers = speakers
        self.diarizer = diarizer
    }

    /// N 从 1 起，按首次出现的顺序编号；一段的标签取与它时间重叠最长的分离结果
    public func run(versionID: UUID, systemTrack: URL, progress: (Double) -> Void) throws {
        // 每次分离都从"说话人 1"重新编号，上一轮的改名对不上人，清掉
        if let speakers, let meetingID = try transcripts.meetingID(ofVersion: versionID) {
            try speakers.removeAll(meetingID: meetingID)
        }
        let system = try transcripts.segments(versionID: versionID).filter { $0.channel == .system }
        guard !system.isEmpty, FileManager.default.fileExists(atPath: systemTrack.path) else {
            progress(1)
            return
        }
        progress(0)
        // 整路载入：2 小时约 460MB，可接受（见计划）
        let samples = try PCMTrackReader.readAll(systemTrack)
        let raw = try diarizer().diarize(samples)
        progress(0.8)
        guard !raw.isEmpty else {
            progress(1)
            return
        }
        let turns = SpeakerMerger.merge(raw, embeddings: voices(of: raw, in: samples))
        progress(0.9)
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
            // 分离没覆盖到的短句归给时间上最近的说话人，否则会多显示出一个"对方"
            let speaker = best?.speaker ?? turns.min { gap(seg, $0) < gap(seg, $1) }?.speaker
            if let speaker, let name = names[speaker] {
                try transcripts.setSpeakerLabel(seg.id, label: name)
            }
        }
        progress(1)
    }

    private func gap(_ seg: TranscriptSegment, _ t: SpeakerTurn) -> TimeInterval {
        max(0, max(seg.start, t.start) - min(seg.end, t.end))
    }

    /// 每个说话人全部音频的声纹。太短的不算（不可信）；算失败不影响转写，只是少合并
    private func voices(of turns: [SpeakerTurn], in samples: [Float]) -> [Int: [Float]] {
        guard let embedder else { return [:] }
        var audio: [Int: [Float]] = [:]
        for t in turns {
            let from = max(0, Int(t.start * 16_000)), to = min(samples.count, Int(t.end * 16_000))
            if from < to { audio[t.speaker, default: []] += samples[from..<to] }
        }
        return audio.compactMapValues { pcm in
            pcm.count >= Int(SpeakerMerger.minSpeech * 16_000) ? try? embedder(pcm) : nil
        }
    }
}

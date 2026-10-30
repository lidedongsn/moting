import Foundation
import MotingASR
import MotingCapture
import MotingCore
import MotingStorage

/// 会后转写：为会议新建正式稿版本，两路逐段（VAD 切分）识别、加标点、逐段落库
public struct TranscribeStep {
    private let paths: AppPaths
    private let transcripts: TranscriptRepository
    private let makeRecognizer: () throws -> OfflineRecognizing
    private let makeSegmenter: () throws -> SpeechSegmenting
    private let makePunctuator: (() throws -> Punctuating)?

    public init(paths: AppPaths, transcripts: TranscriptRepository,
                makeRecognizer: @escaping () throws -> OfflineRecognizing,
                makeSegmenter: @escaping () throws -> SpeechSegmenting,
                makePunctuator: (() throws -> Punctuating)?) {
        self.paths = paths
        self.transcripts = transcripts
        self.makeRecognizer = makeRecognizer
        self.makeSegmenter = makeSegmenter
        self.makePunctuator = makePunctuator
    }

    /// previousVersion：上次中断留下的未完成版本，先删掉再重建。返回新版本 id
    public func run(meetingID: UUID, modelID: String, previousVersion: UUID?,
                    progress: (Double) -> Void) throws -> UUID {
        if let previousVersion { try transcripts.deleteVersion(previousVersion) }
        let versionID = try transcripts.createVersion(meetingID: meetingID, kind: .final,
                                                      engine: "sherpa-onnx \(sherpaOnnxVersion()) offline",
                                                      model: modelID, createdAt: Date())
        let recognizer = try makeRecognizer()
        let segmenter = try makeSegmenter()
        let punctuator = try makePunctuator?()

        // 按两路时长分配进度
        let tracks: [(AudioChannel, URL, Int)] = AudioChannel.allCases.compactMap { ch in
            let url = paths.trackURL(meetingID, ch)
            guard let n = try? PCMTrackReader.sampleCount(url), n > 0 else { return nil }
            return (ch, url, n)
        }
        let grand = Double(max(tracks.reduce(0) { $0 + $1.2 }, 1))
        var before = 0
        progress(0)
        for (ch, url, total) in tracks {
            let reader = try PCMMixReader(urls: [url])
            let base = before
            try segmenter.segment(reader: { try reader.read(at: $0, count: $1) }, total: total) { span in
                var text = try recognizer.recognize(span.samples)
                if !text.isEmpty {
                    text = punctuator?.punctuate(text) ?? text
                    try transcripts.append(TranscriptSegment(
                        versionID: versionID, channel: ch,
                        start: Double(span.start) / 16_000,
                        end: Double(span.start + span.samples.count) / 16_000, text: text))
                }
                progress(min(1, Double(base + span.start + span.samples.count) / grand))
            }
            before += total
            progress(min(1, Double(before) / grand))
        }
        progress(1)
        return versionID
    }
}

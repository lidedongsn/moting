import Foundation
import MotingASR
import MotingCore
import MotingStorage

public enum PipelineError: LocalizedError {
    case missingVersion

    public var errorDescription: String? {
        switch self {
        case .missingVersion: "缺少转写结果，请重新转写"
        }
    }
}

/// 把各步骤串起来：负责按需下载模型、加载与释放（每步结束模型即释放，同一时间只占一个大模型）
public struct DefaultStepRunner: PipelineStepRunner {
    private let paths: AppPaths
    private let transcripts: TranscriptRepository
    private let store: ModelStore
    private let speakers: SpeakerRepository?

    public init(paths: AppPaths, transcripts: TranscriptRepository, store: ModelStore, speakers: SpeakerRepository? = nil) {
        self.speakers = speakers
        self.paths = paths
        self.transcripts = transcripts
        self.store = store
    }

    public func run(_ step: JobStep, job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> Job {
        var job = job
        switch step {
        case .transcribe:
            let model = OfflineCatalog.model(id: job.modelID) ?? OfflineCatalog.default
            var needed: [any DownloadableModel] = [OfflineCatalog.vad, model]
            if !model.hasPunctuation { needed.append(OfflineCatalog.punctuation) }
            try await ensureInstalled(needed)
            let hotwords = Self.loadHotwords(paths.hotwordsURL)
            let store = store
            job.versionID = try TranscribeStep(
                paths: paths, transcripts: transcripts,
                makeRecognizer: { try SherpaOfflineRecognizer(model: model, directory: store.directory(for: model), hotwords: hotwords) },
                makeSegmenter: { try VoiceSegmenter(vadModel: store.directory(for: OfflineCatalog.vad).appendingPathComponent("silero_vad.onnx")) },
                makePunctuator: model.hasPunctuation ? nil : {
                    try Punctuator(model: OfflineCatalog.punctuation, directory: store.directory(for: OfflineCatalog.punctuation))
                }
            ).run(meetingID: job.meetingID, modelID: model.id, previousVersion: job.versionID, progress: progress)
        case .diarize:
            guard let v = job.versionID else { throw PipelineError.missingVersion }
            try await ensureInstalled([OfflineCatalog.segmentation, OfflineCatalog.embedding])
            let store = store
            try DiarizeStep(transcripts: transcripts, speakers: speakers) {
                try SherpaDiarizer(segmentation: OfflineCatalog.segmentation, embedding: OfflineCatalog.embedding,
                                   directory: { store.directory(for: $0) })
            }.run(versionID: v, systemTrack: paths.trackURL(job.meetingID, .system), progress: progress)
        case .filterVoice:
            guard let v = job.versionID else { throw PipelineError.missingVersion }
            let hasVoiceprint = FileManager.default.fileExists(atPath: paths.voiceprintURL.path)
            if hasVoiceprint { try await ensureInstalled([OfflineCatalog.embedding]) }
            let store = store
            let outcome = try FilterVoiceStep(transcripts: transcripts).run(
                versionID: v, micTrack: paths.trackURL(job.meetingID, .mic),
                voiceprint: hasVoiceprint ? paths.voiceprintURL : nil,
                matcher: { try VoiceprintMatcher(embeddingModel: OfflineCatalog.embedding,
                                                 directory: store.directory(for: OfflineCatalog.embedding)) },
                progress: progress)
            job.filterOutcome = outcome.rawValue
        case .merge:
            guard let v = job.versionID else { throw PipelineError.missingVersion }
            try MergeStep(transcripts: transcripts).run(versionID: v, micTrack: paths.trackURL(job.meetingID, .mic),
                                                        systemTrack: paths.trackURL(job.meetingID, .system))
            progress(1)
        }
        return job
    }

    private func ensureInstalled(_ models: [any DownloadableModel]) async throws {
        for m in models {
            try await ensureInstalled(m)
        }
    }

    private func ensureInstalled<M: DownloadableModel>(_ m: M) async throws {
        guard !store.isInstalled(m) else { return }
        try await store.install(m) { _ in }
    }

    /// 每行一个，去掉空行与首尾空白
    public static func loadHotwords(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

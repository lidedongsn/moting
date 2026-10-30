import CSherpaOnnx
import Foundation

/// 声纹：提取说话人向量并比对（3D-Speaker CAM++）
public final class VoiceprintMatcher {
    private let handle: OpaquePointer

    public init(embeddingModel: AuxModel, directory: URL) throws {
        guard let name = embeddingModel.files.first?.name else { throw OfflineASRError.modelMissing(embeddingModel.id) }
        let path = directory.appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: path) else { throw OfflineASRError.modelMissing(name) }
        let pool = CStringPool()
        var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
        config.model = pool.c(path)
        config.num_threads = 2
        config.provider = pool.c("cpu")
        guard let h = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config) else {
            throw OfflineASRError.createFailed(embeddingModel.id)
        }
        handle = h
    }

    deinit {
        SherpaOnnxDestroySpeakerEmbeddingExtractor(handle)
    }

    /// 16kHz 单声道；音频太短（模型不就绪）时返回空数组
    public func embedding(_ samples: [Float]) throws -> [Float] {
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(handle) else {
            throw OfflineASRError.createFailed("embedding stream")
        }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress, Int32($0.count)) }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(handle, stream) != 0,
              let v = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(handle, stream) else { return [] }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v) }
        let dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(handle))
        return Array(UnsafeBufferPointer(start: v, count: dim))
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// 小端 Float32 裸文件
    public static func save(_ e: [Float], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url, options: .atomic)
    }

    public static func load(_ url: URL) throws -> [Float] {
        let d = try Data(contentsOf: url)
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// 声纹过滤的取舍参数
public enum VoiceprintPolicy {
    /// 相似度低于此值的麦克风片段视为旁人。TTS 实测同声 0.89、异声 0.53，暂定 0.65，Task 9 用真实录音校准
    public static let threshold: Float = 0.65
    /// 过滤后麦克风一路剩余时长低于原来的这个比例，视为声纹不可靠，放弃过滤
    public static let minKeptRatio: Double = 0.3
}

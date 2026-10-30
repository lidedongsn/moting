import CSherpaOnnx
import Foundation

/// 离线（整段）识别（测试可用假实现）
public protocol OfflineRecognizing: AnyObject {
    func recognize(_ samples: [Float]) throws -> String
}

/// sherpa-onnx 离线识别器
public final class SherpaOfflineRecognizer: OfflineRecognizing {
    private let handle: OpaquePointer
    private let model: OfflineModel
    /// 仅 transducer：每个流单独带热词（一行一个）
    private let streamHotwords: String?

    public init(model: OfflineModel, directory: URL, hotwords: [String], numThreads: Int = 4) throws {
        self.model = model
        let pool = CStringPool()
        func path(_ role: String) throws -> UnsafePointer<CChar> {
            guard let name = model.roles[role] else { throw OfflineASRError.modelMissing(role) }
            let p = directory.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: p) else { throw OfflineASRError.modelMissing(name) }
            return pool.c(p)
        }
        let words = hotwords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.num_threads = Int32(numThreads)
        config.model_config.provider = pool.c("cpu")
        config.decoding_method = pool.c("greedy_search")
        var hotwordsForStream: String?
        switch model.kind {
        case .senseVoice:
            config.model_config.sense_voice.model = try path("model")
            config.model_config.sense_voice.language = pool.c("auto")
            config.model_config.sense_voice.use_itn = 1
            config.model_config.tokens = try path("tokens")
        case .paraformer:
            config.model_config.paraformer.model = try path("model")
            config.model_config.tokens = try path("tokens")
        case .transducer:
            config.model_config.transducer.encoder = try path("encoder")
            config.model_config.transducer.decoder = try path("decoder")
            config.model_config.transducer.joiner = try path("joiner")
            config.model_config.tokens = try path("tokens")
            if !words.isEmpty {
                // 热词需要束搜索；中英混合的 BPE 模型按"汉字 + BPE"切分热词
                config.decoding_method = pool.c("modified_beam_search")
                config.max_active_paths = 4
                config.hotwords_score = 1.5
                config.model_config.modeling_unit = pool.c("cjkchar+bpe")
                config.model_config.bpe_vocab = try path("bpe")
                hotwordsForStream = words.joined(separator: "\n")
            }
        case .qwen3ASR:
            config.model_config.qwen3_asr.conv_frontend = try path("conv_frontend")
            config.model_config.qwen3_asr.encoder = try path("encoder")
            config.model_config.qwen3_asr.decoder = try path("decoder")
            config.model_config.qwen3_asr.tokenizer = try path("tokenizer")
            config.model_config.qwen3_asr.max_total_len = 512
            config.model_config.qwen3_asr.max_new_tokens = 256
            config.model_config.qwen3_asr.temperature = 1e-6
            config.model_config.qwen3_asr.top_p = 0.8
            config.model_config.qwen3_asr.seed = 42
            if !words.isEmpty { config.model_config.qwen3_asr.hotwords = pool.c(words.joined(separator: ",")) }
        case .fireRedASR:
            config.model_config.fire_red_asr.encoder = try path("encoder")
            config.model_config.fire_red_asr.decoder = try path("decoder")
            config.model_config.tokens = try path("tokens")
        }
        guard let h = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw OfflineASRError.createFailed(model.id)
        }
        handle = h
        streamHotwords = hotwordsForStream
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(handle)
    }

    public func recognize(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        let stream: OpaquePointer? = streamHotwords.map { words in
            words.withCString { SherpaOnnxCreateOfflineStreamWithHotwords(handle, $0) }
        } ?? SherpaOnnxCreateOfflineStream(handle)
        guard let stream else { throw OfflineASRError.createFailed("stream") }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16_000, $0.baseAddress, Int32($0.count)) }
        SherpaOnnxDecodeOfflineStream(handle, stream)
        guard let r = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(r) }
        return r.pointee.text.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

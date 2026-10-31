import CSherpaOnnx
import Foundation

/// 流式识别器抽象，便于 LiveTranscriber 用假实现测试
public protocol StreamingRecognizing: AnyObject {
    func makeStream() -> RecognitionStream
}

public protocol RecognitionStream: AnyObject {
    /// 16kHz 单声道
    func accept(_ samples: [Float])
    /// 解码所有就绪帧
    func decode()
    /// 当前句的部分结果
    var text: String { get }
    var isEndpoint: Bool { get }
    /// 端点后开始下一句
    func reset()
    /// 不会再有输入：让识别器把缓存中的尾部也给出结果
    func inputFinished()
}

public enum RecognizerError: Error {
    case modelNotInstalled(String)
    case createFailed
}

/// sherpa-onnx 在线识别器；一个识别器可开多个流（每路音频一个）
public final class SherpaRecognizer: StreamingRecognizing {
    fileprivate let handle: OpaquePointer

    public init(model: StreamingModel, directory: URL, numThreads: Int = 2) throws {
        func path(_ role: String) throws -> String {
            guard let name = model.roles[role] else { return "" }
            let p = directory.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: p) else { throw RecognizerError.modelNotInstalled(name) }
            return p
        }
        // C 字符串在创建期间保持有效，结束后释放
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }

        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        switch model.kind {
        case .transducer:
            config.model_config.transducer.encoder = c(try path("encoder"))
            config.model_config.transducer.decoder = c(try path("decoder"))
            config.model_config.transducer.joiner = c(try path("joiner"))
        case .paraformer:
            config.model_config.paraformer.encoder = c(try path("encoder"))
            config.model_config.paraformer.decoder = c(try path("decoder"))
        }
        config.model_config.tokens = c(try path("tokens"))
        config.model_config.num_threads = Int32(numThreads)
        config.model_config.provider = c("cpu")
        config.model_config.debug = 0
        config.decoding_method = c("greedy_search")
        config.enable_endpoint = 1
        config.rule1_min_trailing_silence = 2.4
        config.rule2_min_trailing_silence = 1.2
        config.rule3_min_utterance_length = 20

        guard let h = SherpaOnnxCreateOnlineRecognizer(&config) else { throw RecognizerError.createFailed }
        handle = h
    }

    deinit {
        SherpaOnnxDestroyOnlineRecognizer(handle)
    }

    public func makeStream() -> RecognitionStream {
        SherpaStream(recognizer: self)
    }
}

private final class SherpaStream: RecognitionStream {
    // 持有识别器，保证流销毁前识别器仍有效
    private let recognizer: SherpaRecognizer
    private let handle: OpaquePointer

    init(recognizer: SherpaRecognizer) {
        self.recognizer = recognizer
        handle = SherpaOnnxCreateOnlineStream(recognizer.handle)
    }

    deinit {
        SherpaOnnxDestroyOnlineStream(handle)
    }

    func accept(_ samples: [Float]) {
        samples.withUnsafeBufferPointer {
            SherpaOnnxOnlineStreamAcceptWaveform(handle, 16_000, $0.baseAddress, Int32($0.count))
        }
    }

    func decode() {
        while SherpaOnnxIsOnlineStreamReady(recognizer.handle, handle) != 0 {
            SherpaOnnxDecodeOnlineStream(recognizer.handle, handle)
        }
    }

    var text: String {
        guard let r = SherpaOnnxGetOnlineStreamResult(recognizer.handle, handle) else { return "" }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(r) }
        return cleanRecognizedText(r.pointee.text.map { String(cString: $0) } ?? "")
    }

    var isEndpoint: Bool {
        SherpaOnnxOnlineStreamIsEndpoint(recognizer.handle, handle) != 0
    }

    func reset() {
        SherpaOnnxOnlineStreamReset(recognizer.handle, handle)
    }

    func inputFinished() {
        SherpaOnnxOnlineStreamInputFinished(handle)
    }
}

/// 去掉模型控制符（流式 Paraformer 句末会带出 </s>）和首尾空白
func cleanRecognizedText(_ raw: String) -> String {
    raw.replacingOccurrences(of: "</s>", with: "").replacingOccurrences(of: "<s>", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

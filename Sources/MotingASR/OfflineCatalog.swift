import Foundation

public enum OfflineModelKind: String, Sendable {
    case senseVoice, paraformer, transducer, qwen3ASR, fireRedASR
}

/// 会后精准转写用的离线识别模型
public struct OfflineModel: DownloadableModel, Identifiable, Equatable {
    public var id: String
    public var displayName: String
    public var source: ModelSource
    public var files: [ModelFile]
    public var kind: OfflineModelKind
    /// 角色 → 文件名；以 "/" 结尾的是目录（如 Qwen3 的 tokenizer/）
    public var roles: [String: String]
    /// 自带标点则跳过标点模型
    public var hasPunctuation: Bool
    public var supportsHotwords: Bool
}

/// 辅助模型：人声检测、说话人分段、声纹、标点
public struct AuxModel: DownloadableModel, Identifiable, Equatable {
    public var id: String
    public var displayName: String
    public var source: ModelSource
    public var files: [ModelFile]

    public init(id: String, displayName: String, source: ModelSource, files: [ModelFile]) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.files = files
    }
}

/// 离线识别候选与辅助模型。sha256 / size 取自 HuggingFace API 与 GitHub 发布页（2026-10-30）
public enum OfflineCatalog {
    private static let github = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download")!

    public static let senseVoice = OfflineModel(
        id: "offline-sense-voice-int8-2025-09-09", displayName: "SenseVoice（中英日韩粤）",
        source: .huggingFace(repo: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"),
        files: [
            ModelFile(name: "model.int8.onnx", sha256: "12ca1a2ae7ecf3e0019ef2822307ee0b5cadc9196569e379b4c4026f8205276d", size: 237_115_547),
            ModelFile(name: "tokens.txt", sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc", size: 315_894),
        ],
        kind: .senseVoice, roles: ["model": "model.int8.onnx", "tokens": "tokens.txt"],
        hasPunctuation: true, supportsHotwords: false)

    public static let paraformerZh = OfflineModel(
        id: "offline-paraformer-zh-int8-2025-10-07", displayName: "Paraformer 中文大模型",
        source: .huggingFace(repo: "csukuangfj/sherpa-onnx-paraformer-zh-int8-2025-10-07"),
        files: [
            ModelFile(name: "model.int8.onnx", sha256: "53813ee1d41722cc6370a571c887e6d0b391d25b8312cf714a31af85ea603812", size: 238_429_929),
            ModelFile(name: "tokens.txt", sha256: "59aba8873a2ed1e122c25fee421e25f283b63290efbde85c1f01a853d83cb6e6", size: 75_756),
        ],
        kind: .paraformer, roles: ["model": "model.int8.onnx", "tokens": "tokens.txt"],
        hasPunctuation: false, supportsHotwords: false)

    public static let xasrTransducer = OfflineModel(
        id: "offline-x-asr-zh-en-punct-int8-2026-06-03", displayName: "X-ASR 中英（带标点，支持热词）",
        source: .huggingFace(repo: "csukuangfj2/sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03"),
        files: [
            ModelFile(name: "encoder-epoch-99-avg-1.int8.onnx", sha256: "fe0198b52626f2a1012ebb6d6a7259c5137c4c964f3a524135e353f4687b5d14", size: 161_744_450),
            ModelFile(name: "decoder-epoch-99-avg-1.onnx", sha256: "a9fe7c320337e6f510809c028a8accf074d45f42aab852e2d29830babc41a3f9", size: 11_309_084),
            ModelFile(name: "joiner-epoch-99-avg-1.int8.onnx", sha256: "aedb7fa697b2ab43f20499826fff7c997eea7d67db77be97769aeeeb726e63b3", size: 2_581_422),
            ModelFile(name: "tokens.txt", sha256: "b818a60878b9aae978cbb8ad594acbd403d76d1af2e31ef4197c84e2dbdba27c", size: 58_806),
            ModelFile(name: "bpe.model", sha256: "f87a38025a5fdd1e4e9591f6a44bb81295097ce0b80df6f4ab9f44e52c64ca5f", size: 119_265),
        ],
        kind: .transducer,
        roles: ["encoder": "encoder-epoch-99-avg-1.int8.onnx", "decoder": "decoder-epoch-99-avg-1.onnx",
                "joiner": "joiner-epoch-99-avg-1.int8.onnx", "tokens": "tokens.txt", "bpe": "bpe.model"],
        hasPunctuation: true, supportsHotwords: true)

    public static let qwen3ASR = OfflineModel(
        id: "offline-qwen3-asr-0.6b-int8-2026-03-25", displayName: "Qwen3-ASR 0.6B（支持热词）",
        source: .huggingFace(repo: "csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"),
        files: [
            ModelFile(name: "conv_frontend.onnx", sha256: "d22dc4423e0940e49884e903d2ea2f7e5567c14fc1aed97e4e26d6b8f208ef9e", size: 44_148_281),
            ModelFile(name: "encoder.int8.onnx", sha256: "60748d3e6744a57c9c91e1b17424a6c2990567e8adceb0783940c03ed98fa9d9", size: 182_491_662),
            ModelFile(name: "decoder.int8.onnx", sha256: "4f6885be5959ae26af3089d38ee7972c5fafbeeb1cf8d5e76eab6d8b61ca5771", size: 755_914_231),
            ModelFile(name: "tokenizer/merges.txt", sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5", size: 1_671_853),
            ModelFile(name: "tokenizer/tokenizer_config.json", sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c", size: 12_487),
            ModelFile(name: "tokenizer/vocab.json", sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910", size: 2_776_833),
        ],
        kind: .qwen3ASR,
        roles: ["conv_frontend": "conv_frontend.onnx", "encoder": "encoder.int8.onnx",
                "decoder": "decoder.int8.onnx", "tokenizer": "tokenizer/"],
        hasPunctuation: true, supportsHotwords: true)

    public static let fireRedASR2 = OfflineModel(
        id: "offline-fire-red-asr2-zh-en-int8-2026-02-26", displayName: "FireRedASR2 中英",
        source: .huggingFace(repo: "csukuangfj2/sherpa-onnx-fire-red-asr2-zh_en-int8-2026-02-26"),
        files: [
            ModelFile(name: "encoder.int8.onnx", sha256: "54048d66b6e8f3c80ea7ce95efe794587b0fd81d7271651d0decd3803852ae82", size: 817_286_833),
            ModelFile(name: "decoder.int8.onnx", sha256: "b840ce7196ae4a14d05ae84bbf56082b6b61ccec5610fda907dddbcea37354ff", size: 417_291_928),
            ModelFile(name: "tokens.txt", sha256: "1bc613de2112d257e61a349c3e72d1b1a9cf19c33d3ca954197ad2171e5ea07b", size: 79_172),
        ],
        kind: .fireRedASR,
        roles: ["encoder": "encoder.int8.onnx", "decoder": "decoder.int8.onnx", "tokens": "tokens.txt"],
        hasPunctuation: false, supportsHotwords: false)

    public static let all: [OfflineModel] = [senseVoice, paraformerZh, xasrTransducer, qwen3ASR, fireRedASR2]

    /// 默认离线模型；Task 9 对比后由用户选定
    public static var `default`: OfflineModel { senseVoice }

    public static func model(id: String) -> OfflineModel? {
        all.first { $0.id == id }
    }

    public static let vad = AuxModel(
        id: "aux-silero-vad", displayName: "人声检测（Silero VAD）",
        source: .direct(baseURL: github.appendingPathComponent("asr-models")),
        files: [ModelFile(name: "silero_vad.onnx", sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6", size: 643_854)])

    public static let segmentation = AuxModel(
        id: "aux-pyannote-segmentation-3-0", displayName: "说话人分段（pyannote 3.0）",
        source: .huggingFace(repo: "csukuangfj/sherpa-onnx-pyannote-segmentation-3-0"),
        files: [ModelFile(name: "model.int8.onnx", sha256: "d582f4b4c6b48205de7e0643c57df0df5615a3c176189be3fc461e9d18827b5d", size: 1_540_506)])

    public static let embedding = AuxModel(
        id: "aux-3dspeaker-campplus-zh-en", displayName: "声纹（3D-Speaker CAM++ 中英）",
        source: .direct(baseURL: github.appendingPathComponent("speaker-recongition-models")),
        files: [ModelFile(name: "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",
                          sha256: "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2", size: 28_281_164)])

    public static let punctuation = AuxModel(
        id: "aux-punct-ct-transformer-zh-en-int8", displayName: "标点（CT-Transformer 中英）",
        source: .githubArchive(
            url: github.appendingPathComponent("punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2"),
            sha256: "c0d5aa5f8eeb686032345e180bedf39319dc2e0556781c6264bcadba8328a6e1", size: 64_717_756,
            stripPrefix: "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"),
        files: [ModelFile(name: "model.int8.onnx", sha256: "65a3fb9f5ad7bfb96bf69e0dc4481df97f6ee60513c1d94ce981ba6effd524b1", size: 75_519_198)])

    public static let auxiliary: [AuxModel] = [vad, segmentation, embedding, punctuation]
}

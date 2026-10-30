import Foundation

public enum StreamingModelKind: String, Sendable {
    case transducer, paraformer
}

public struct ModelFile: Sendable, Equatable {
    /// 仓库内路径，也是本地文件名
    public var name: String
    public var sha256: String
    public var size: Int64

    public init(name: String, sha256: String, size: Int64) {
        self.name = name
        self.sha256 = sha256
        self.size = size
    }
}

/// 模型从哪里下载
public enum ModelSource: Sendable, Equatable {
    /// HuggingFace 仓库，逐文件下载，可回退镜像
    case huggingFace(repo: String)
    /// 直链：文件地址为 baseURL/<文件名>
    case direct(baseURL: URL)
    /// GitHub 发布页的 tar.bz2：整包校验后只解出 files 中的文件（包内路径为 stripPrefix/<文件名>）
    case githubArchive(url: URL, sha256: String, size: Int64, stripPrefix: String)
}

/// 可下载安装的模型；ModelStore 只依赖这个协议
public protocol DownloadableModel: Sendable {
    var id: String { get }
    var displayName: String { get }
    var source: ModelSource { get }
    /// 文件名可含子目录（如 tokenizer/vocab.json）
    var files: [ModelFile] { get }
}

extension DownloadableModel {
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct StreamingModel: Identifiable, Sendable, Equatable, DownloadableModel {
    /// 本地目录名
    public var id: String
    public var displayName: String
    /// HuggingFace 仓库，如 "csukuangfj/xxx"
    public var repo: String
    public var kind: StreamingModelKind
    public var files: [ModelFile]
    /// 角色 → 文件名。transducer：encoder/decoder/joiner/tokens；paraformer：encoder/decoder/tokens
    public var roles: [String: String]

    public init(id: String, displayName: String, repo: String, kind: StreamingModelKind,
                files: [ModelFile], roles: [String: String]) {
        self.id = id
        self.displayName = displayName
        self.repo = repo
        self.kind = kind
        self.files = files
        self.roles = roles
    }

    public var source: ModelSource { .huggingFace(repo: repo) }
}

/// 实时识别候选模型（只收录 int8 版本）。sha256 / size 取自 HuggingFace API
public enum ModelCatalog {
    public static let bilingualZipformer = StreamingModel(
        id: "zipformer-bilingual-zh-en-2023-02-20",
        displayName: "中英双语 Zipformer（2023）",
        repo: "csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20",
        kind: .transducer,
        files: [
            ModelFile(name: "encoder-epoch-99-avg-1.int8.onnx", sha256: "8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b", size: 181_895_032),
            ModelFile(name: "decoder-epoch-99-avg-1.onnx", sha256: "2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d", size: 13_876_452),
            ModelFile(name: "joiner-epoch-99-avg-1.int8.onnx", sha256: "1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0", size: 3_228_404),
            ModelFile(name: "tokens.txt", sha256: "a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3", size: 56_317),
        ],
        roles: ["encoder": "encoder-epoch-99-avg-1.int8.onnx", "decoder": "decoder-epoch-99-avg-1.onnx",
                "joiner": "joiner-epoch-99-avg-1.int8.onnx", "tokens": "tokens.txt"]
    )

    public static let chineseZipformer2025 = StreamingModel(
        id: "zipformer-zh-int8-2025-06-30",
        displayName: "中文 Zipformer（2025）",
        repo: "csukuangfj/sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30",
        kind: .transducer,
        files: [
            ModelFile(name: "encoder.int8.onnx", sha256: "5ac51e27981bb4dab01bb9be4958453ba50c3b61c063ddda0eab23fd3671aa4f", size: 161_141_793),
            ModelFile(name: "decoder.onnx", sha256: "06522ad63cec0fdf6809f4e1db9bb4f7d710c34582e3b35db62ac60eccafac7e", size: 5_165_083),
            ModelFile(name: "joiner.int8.onnx", sha256: "b34584dc6f561089e1d747fedebb3765f2caa72c927ef54d7ca55e5ae40a814b", size: 1_033_416),
            ModelFile(name: "tokens.txt", sha256: "6193c7ea1c96d0d9a1e9652789b40d13a8a913b434a5451e93158f5a09fd6652", size: 20_628),
        ],
        roles: ["encoder": "encoder.int8.onnx", "decoder": "decoder.onnx",
                "joiner": "joiner.int8.onnx", "tokens": "tokens.txt"]
    )

    public static let bilingualParaformer = StreamingModel(
        id: "paraformer-bilingual-zh-en",
        displayName: "中英双语 Paraformer",
        repo: "csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en",
        kind: .paraformer,
        files: [
            ModelFile(name: "encoder.int8.onnx", sha256: "81a70226a8934e6ed92aa1d4fc486b428b5398e2f2619ed4897b7294cab90e9a", size: 165_462_184),
            ModelFile(name: "decoder.int8.onnx", sha256: "f3cca9f77bb9d93c8fcbfb63ae617b6b1ee96818df3aa3b151c40658fe38594f", size: 71_664_561),
            ModelFile(name: "tokens.txt", sha256: "59aba8873a2ed1e122c25fee421e25f283b63290efbde85c1f01a853d83cb6e6", size: 75_756),
        ],
        roles: ["encoder": "encoder.int8.onnx", "decoder": "decoder.int8.onnx", "tokens": "tokens.txt"]
    )

    public static let all: [StreamingModel] = [bilingualZipformer, chineseZipformer2025, bilingualParaformer]

    /// 默认模型：2026-10-30 三模型对比后由用户选定（中英文都较好、内存最省）
    public static var `default`: StreamingModel { bilingualParaformer }

    public static func model(id: String) -> StreamingModel? {
        all.first { $0.id == id }
    }
}

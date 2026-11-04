import Foundation
import MotingCore

/// AI 纪要服务配置（OpenAI 兼容的 Chat Completions 接口）。API Key 不在这里，存钥匙串
public struct SummaryService: Codable, Equatable, Sendable {
    /// 预设标识：deepseek / qwen / kimi / zhipu / doubao / openai / ollama / custom
    public var id: String
    public var name: String
    public var baseURL: String
    public var model: String
    /// 一次能送进去的转写稿字数上限，超过就分段总结再汇总
    public var contextChars: Int
    /// 本机服务不需要 Key
    public var requiresKey: Bool
    /// 常用模型（测试连接后会换成服务实际返回的列表）
    public var suggestedModels: [String]
    /// 去哪里创建 Key
    public var keyPage: String?

    public init(id: String = "custom", name: String, baseURL: String, model: String, contextChars: Int = 300_000,
                requiresKey: Bool = true, suggestedModels: [String] = [], keyPage: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.contextChars = contextChars
        self.requiresKey = requiresKey
        self.suggestedModels = suggestedModels
        self.keyPage = keyPage
    }

    /// 旧版本只存了 name / baseURL / model / contextChars，缺的字段按 DeepSeek 补
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        let base = Self.presets.first { $0.name == name }
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? base?.id ?? "custom"
        self.name = name
        baseURL = try c.decode(String.self, forKey: .baseURL)
        model = try c.decode(String.self, forKey: .model)
        contextChars = try c.decodeIfPresent(Int.self, forKey: .contextChars) ?? base?.contextChars ?? 300_000
        requiresKey = try c.decodeIfPresent(Bool.self, forKey: .requiresKey) ?? base?.requiresKey ?? true
        suggestedModels = try c.decodeIfPresent([String].self, forKey: .suggestedModels) ?? base?.suggestedModels ?? []
        keyPage = try c.decodeIfPresent(String.self, forKey: .keyPage) ?? base?.keyPage
    }

    // 地址和模型名取自各家文档（2026-11）；模型名变得快，界面上可改，测试连接会拉实际列表
    public static let deepSeek = SummaryService(
        id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-flash",
        suggestedModels: ["deepseek-flash", "deepseek-v4-pro"], keyPage: "https://platform.deepseek.com/api_keys")

    public static let presets: [SummaryService] = [
        deepSeek,
        SummaryService(id: "qwen", name: L("通义千问"), baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus",
                       suggestedModels: ["qwen-plus", "qwen-max", "qwen-turbo"], keyPage: "https://bailian.console.aliyun.com/"),
        SummaryService(id: "kimi", name: "Kimi", baseURL: "https://api.moonshot.cn/v1", model: "kimi-k3.1-pro",
                       suggestedModels: ["kimi-k3.1-pro", "kimi-k3.1-pro-highspeed"], keyPage: "https://platform.kimi.com/console/api-keys"),
        SummaryService(id: "zhipu", name: L("智谱 GLM"), baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-5.3",
                       suggestedModels: ["glm-5.3", "glm-5.3-flash"], keyPage: "https://open.bigmodel.cn/usercenter/apikeys"),
        SummaryService(id: "doubao", name: L("豆包"), baseURL: "https://ark.cn-beijing.volces.com/api/v3", model: "doubao-seed-2-1-pro-260915",
                       suggestedModels: ["doubao-seed-2-1-pro-260915"], keyPage: "https://console.volcengine.com/ark"),
        SummaryService(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-6.1-sol",
                       suggestedModels: ["gpt-6.1-sol", "gpt-6-luna", "gpt-6-astra"], keyPage: "https://platform.openai.com/api-keys"),
        // 本机模型上下文通常只有几千 token，按小上限分段
        SummaryService(id: "ollama", name: L("本机 Ollama"), baseURL: "http://localhost:11434/v1", model: "qwen3",
                       contextChars: 6_000, requiresKey: false, suggestedModels: ["qwen3", "qwen3:14b", "llama3.3"],
                       keyPage: "https://ollama.com"),
        SummaryService(id: "custom", name: L("自定义"), baseURL: "https://", model: ""),
    ]

    public static func preset(_ id: String) -> SummaryService? {
        presets.first { $0.id == id }
    }

    /// 数据不出这台 Mac
    public var isLocal: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    /// 只允许 HTTPS；本机（如 Ollama）可以用 HTTP，数据不出这台电脑
    public var validationError: String? {
        guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased(), url.host != nil else {
            return L("服务地址不是有效的网址")
        }
        if scheme == "https" || (scheme == "http" && isLocal) { return nil }
        return L("为保护隐私，只能使用 https 地址（本机服务除外）")
    }
}

public enum SummaryError: LocalizedError, Equatable {
    case notConfigured
    case emptyTranscript
    /// 模型两次都没有返回可用的 JSON；附上最后一次的原文
    case unparseable(raw: String)
    case http(status: Int, message: String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: L("还没有配置 AI 纪要服务，请在设置里选择服务并填写 API Key。")
        case .emptyTranscript: L("这场会议还没有转写内容。")
        case .unparseable: L("模型返回的内容无法解析，已保存原文。可以稍后重新生成。")
        case .http(let status, let message): "\(Self.describe(status))\(message.isEmpty ? "" : "（\(message)）")"
        case .network(let m): L("连不上纪要服务：\(m)")
        }
    }

    private static func describe(_ status: Int) -> String {
        switch status {
        case 401: L("API Key 无效，请在设置里检查。")
        case 402: L("账户余额不足，请到服务商处充值。")
        case 429: L("请求太频繁，稍后再试。")
        case 500...599: L("纪要服务暂时不可用（\(status)），稍后再试。")
        default: L("纪要服务返回错误 \(status)。")
        }
    }
}

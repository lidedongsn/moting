import Foundation

/// AI 纪要服务配置（OpenAI 兼容的 Chat Completions 接口）。API Key 不在这里，存钥匙串
public struct SummaryService: Codable, Equatable, Sendable {
    public var name: String
    public var baseURL: String
    public var model: String
    /// 一次能送进去的转写稿字数上限，超过就分段总结再汇总
    public var contextChars: Int

    public init(name: String, baseURL: String, model: String, contextChars: Int = 300_000) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.contextChars = contextChars
    }

    /// DeepSeek 预设：上下文 1M token，字数上限留足余量
    public static let deepSeek = SummaryService(name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-flash")
    public static let deepSeekModels = ["deepseek-flash", "deepseek-v4-pro"]

    /// 只允许 HTTPS；本机（如 Ollama）可以用 HTTP，数据不出这台电脑
    public var validationError: String? {
        guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return "服务地址不是有效的网址"
        }
        if scheme == "https" { return nil }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host) { return nil }
        return "为保护隐私，只能使用 https 地址（本机服务除外）"
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
        case .notConfigured: "还没有配置 AI 纪要服务，请在设置里填写 API Key。"
        case .emptyTranscript: "这场会议还没有转写内容。"
        case .unparseable: "模型返回的内容无法解析，已保存原文。可以稍后重新生成。"
        case .http(let status, let message): "\(Self.describe(status))\(message.isEmpty ? "" : "（\(message)）")"
        case .network(let m): "连不上纪要服务：\(m)"
        }
    }

    private static func describe(_ status: Int) -> String {
        switch status {
        case 401: "API Key 无效，请在设置里检查。"
        case 402: "账户余额不足，请到服务商处充值。"
        case 429: "请求太频繁，稍后再试。"
        case 500...599: "纪要服务暂时不可用（\(status)），稍后再试。"
        default: "纪要服务返回错误 \(status)。"
        }
    }
}

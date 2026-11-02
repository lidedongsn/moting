import Foundation

/// 调用大模型：给系统提示和用户内容，返回回复文字
public protocol ChatCompleting: Sendable {
    func complete(system: String, user: String) async throws -> String
}

/// OpenAI 兼容的 Chat Completions 客户端（DeepSeek 等）。
/// 隐私：只发提示词和转写文字；连接不缓存、不存 Cookie；任何错误信息都不带 API Key
public struct OpenAICompatibleClient: ChatCompleting {
    private let service: SummaryService
    private let apiKey: String
    private let session: URLSession

    public init(service: SummaryService, apiKey: String, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.service = service
        self.apiKey = apiKey
        let cfg = sessionConfiguration
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 300
        session = URLSession(configuration: cfg)
    }

    public func complete(system: String, user: String) async throws -> String {
        let data: Data
        do {
            data = try await send(try chatRequest(system: system, user: user, jsonMode: true))
        } catch SummaryError.http(status: 400, _) {
            // 有的服务不支持 JSON 模式参数：去掉再试一次（提示词里已经要求只输出 JSON）
            data = try await send(try chatRequest(system: system, user: user, jsonMode: false))
        }
        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            let choices: [Choice]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw SummaryError.unparseable(raw: String(decoding: data.prefix(2_000), as: UTF8.self))
        }
        return reply.choices.first?.message.content ?? ""
    }

    private func chatRequest(system: String, user: String, jsonMode: Bool) throws -> URLRequest {
        var req = try request("chat/completions")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": service.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0.3,
            "max_tokens": 8_192,
            "stream": false,
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 测试连接：列出可用模型（不消耗额度）
    public func availableModels() async throws -> [String] {
        let data = try await send(try request("models"))
        struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        return (try? JSONDecoder().decode(List.self, from: data))?.data.map(\.id) ?? []
    }

    private func request(_ path: String) throws -> URLRequest {
        if let e = service.validationError { throw SummaryError.network(e) }
        let base = service.baseURL.hasSuffix("/") ? service.baseURL : service.baseURL + "/"
        guard let url = URL(string: path, relativeTo: URL(string: base)) else { throw SummaryError.network("服务地址无效") }
        var req = URLRequest(url: url.absoluteURL)
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SummaryError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Err: Decodable { struct E: Decodable { let message: String? }; let error: E? }
            let message = (try? JSONDecoder().decode(Err.self, from: data))?.error?.message ?? ""
            throw SummaryError.http(status: status, message: redact(message))
        }
        return data
    }

    /// 服务商的错误信息有时会带出 Key，显示前去掉
    private func redact(_ s: String) -> String {
        guard !apiKey.isEmpty else { return s }
        return s.replacingOccurrences(of: apiKey, with: "••••")
    }
}

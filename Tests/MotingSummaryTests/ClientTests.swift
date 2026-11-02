import Foundation
import Testing
@testable import MotingSummary

/// 拦截请求、按设定回复的 URLProtocol
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    /// URLProtocol 里拿到的请求体在 httpBodyStream 里
    static func bodyData(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return request.httpBody }
        stream.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        stream.close()
        return data
    }

    override func startLoading() {
        Self.lastRequest = request
        let body = Self.bodyData(request)
        Self.lastBody = body
        var req = request
        req.httpBody = body
        let (code, reply) = Self.handler?(req) ?? (500, "")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func client() -> OpenAICompatibleClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubProtocol.self]
    return OpenAICompatibleClient(service: .deepSeek, apiKey: "sk-secret-123", sessionConfiguration: cfg)
}

@Suite(.serialized) struct ClientTests {
    @Test func sendsChatCompletionInJSONMode() async throws {
        StubProtocol.handler = { _ in (200, #"{"choices":[{"message":{"content":"{\"overview\":\"好\"}"}}]}"#) }
        let reply = try await client().complete(system: "系统 json", user: "用户")
        #expect(reply == #"{"overview":"好"}"#)
        let req = try #require(StubProtocol.lastRequest)
        #expect(req.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret-123")
        let body = try JSONSerialization.jsonObject(with: try #require(StubProtocol.lastBody)) as! [String: Any]
        #expect(body["model"] as? String == "deepseek-flash")
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        #expect((body["messages"] as? [[String: String]])?.map { $0["role"]! } == ["system", "user"])
    }

    @Test func httpErrorsBecomePlainMessagesWithoutTheKey() async throws {
        for (code, expected) in [(401, "API Key 无效"), (402, "余额不足"), (429, "太频繁")] {
            StubProtocol.handler = { _ in (code, #"{"error":{"message":"bad sk-secret-123"}}"#) }
            do {
                _ = try await client().complete(system: "s", user: "u")
                Issue.record("应当失败")
            } catch {
                #expect(error.localizedDescription.contains(expected))
                #expect(!error.localizedDescription.contains("sk-secret-123"), "错误信息里不能出现 Key")
            }
        }
    }

    @Test func connectionCheckListsModels() async throws {
        StubProtocol.handler = { req in
            req.url?.path == "/models" ? (200, #"{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}"#) : (404, "")
        }
        #expect(try await client().availableModels() == ["deepseek-flash", "deepseek-v4-pro"])
    }
}

@Test func onlyHTTPSIsAllowedExceptLocalhost() {
    #expect(SummaryService.deepSeek.validationError == nil)
    #expect(SummaryService(name: "x", baseURL: "http://example.com/v1", model: "m").validationError != nil)
    #expect(SummaryService(name: "x", baseURL: "http://localhost:11434/v1", model: "m").validationError == nil, "本地 Ollama 可以用 http")
    #expect(SummaryService(name: "x", baseURL: "不是网址", model: "m").validationError != nil)
}

@Test func apiKeyRoundTripsThroughKeychain() throws {
    let store = APIKeyStore(service: "com.lidedongsn.moting.test.\(UUID().uuidString)")
    defer { try? store.delete(account: "DeepSeek") }
    #expect(try store.read(account: "DeepSeek") == nil)
    try store.save("sk-abc", account: "DeepSeek")
    #expect(try store.read(account: "DeepSeek") == "sk-abc")
    try store.save("sk-new", account: "DeepSeek")
    #expect(try store.read(account: "DeepSeek") == "sk-new", "再次保存是覆盖")
    try store.delete(account: "DeepSeek")
    #expect(try store.read(account: "DeepSeek") == nil)
}

@Test func presetsAreHTTPSExceptLocalOllama() {
    #expect(SummaryService.presets.map(\.id) == ["deepseek", "qwen", "kimi", "zhipu", "doubao", "openai", "ollama", "custom"])
    for p in SummaryService.presets where p.id != "custom" {
        #expect(p.validationError == nil, "\(p.name) 的地址应可用")
        #expect(!p.model.isEmpty)
        #expect(p.requiresKey == (p.id != "ollama"))
    }
    #expect(SummaryService.preset("ollama")?.isLocal == true)
    #expect(SummaryService.preset("deepseek")?.isLocal == false)
    #expect(SummaryService.preset("ollama")!.contextChars < 20_000, "本机模型上下文小，要分段")
}

extension ClientTests {
    @Test func localServiceWithoutKeySendsNoAuthorization() async throws {
        StubProtocol.handler = { _ in (200, #"{"choices":[{"message":{"content":"{}"}}]}"#) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        _ = try await OpenAICompatibleClient(service: SummaryService.preset("ollama")!, apiKey: "", sessionConfiguration: cfg)
            .complete(system: "s json", user: "u")
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(StubProtocol.lastRequest?.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test func retriesWithoutJSONModeWhenServiceRejectsIt() async throws {
        nonisolated(unsafe) var calls: [Bool] = []
        StubProtocol.handler = { req in
            let body = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any]
            let json = body?["response_format"] != nil
            calls.append(json)
            return json ? (400, #"{"error":{"message":"response_format is not supported"}}"#)
                        : (200, #"{"choices":[{"message":{"content":"ok"}}]}"#)
        }
        #expect(try await client().complete(system: "s json", user: "u") == "ok")
        #expect(calls == [true, false])
    }
}

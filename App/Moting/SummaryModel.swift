import Foundation
import MotingCore
import MotingStorage
import MotingSummary

/// AI 纪要：服务配置（Key 按服务分别存钥匙串）、生成状态、自动生成开关
@MainActor
final class SummaryModel: ObservableObject {
    static let serviceKey = "summary.service"
    /// 各服务上次用的配置（模型、自定义地址），切换回来时恢复
    static let savedServicesKey = "summary.savedServices"
    /// 精准转写完成后自动生成（默认关：不经用户点击不发送任何内容）
    static let autoKey = "summary.auto"

    @Published var service: SummaryService {
        didSet {
            if let d = try? JSONEncoder().encode(service) { UserDefaults.standard.set(d, forKey: Self.serviceKey) }
            remember(service)
            if oldValue.id != service.id { refreshKey(); availableModels = [] }
        }
    }
    @Published private(set) var hasKey = false
    /// 测试连接后服务实际可用的模型
    @Published private(set) var availableModels: [String] = []
    /// 能生成了：本机服务不要 Key，其他要有 Key
    var isReady: Bool { !service.requiresKey || hasKey }
    @Published private(set) var generating: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    /// 纪要有变化时加一，详情页据此重新读取
    @Published private(set) var revision = 0

    private let env: AppEnvironment?
    private let notifier: Notifier
    private let keys = APIKeyStore.default

    init(env: AppEnvironment?, notifier: Notifier) {
        self.env = env
        self.notifier = notifier
        service = UserDefaults.standard.data(forKey: Self.serviceKey)
            .flatMap { try? JSONDecoder().decode(SummaryService.self, from: $0) } ?? .deepSeek
        refreshKey()
    }

    /// 切换服务：恢复这家上次的配置
    func select(_ presetID: String) {
        guard presetID != service.id, let preset = SummaryService.preset(presetID) else { return }
        service = savedServices()[presetID] ?? preset
    }

    private func refreshKey() {
        hasKey = keys.contains(account: service.name)
    }

    private func savedServices() -> [String: SummaryService] {
        UserDefaults.standard.data(forKey: Self.savedServicesKey)
            .flatMap { try? JSONDecoder().decode([String: SummaryService].self, from: $0) } ?? [:]
    }

    private func remember(_ s: SummaryService) {
        var all = savedServices()
        all[s.id] = s
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: Self.savedServicesKey) }
    }

    /// 空字符串 = 删除
    func setKey(_ key: String) throws {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { try keys.delete(account: service.name) } else { try keys.save(k, account: service.name) }
        hasKey = !k.isEmpty
    }

    /// 测试连接：返回可用模型
    func testConnection() async throws -> [String] {
        let models = try await client().availableModels()
        availableModels = models
        return models
    }

    func stored(_ meetingID: UUID) -> StoredSummary? {
        try? env?.summaries.load(meetingID: meetingID)
    }

    func setTodo(_ meetingID: UUID, _ todoID: UUID, done: Bool) {
        try? env?.summaries.setTodo(meetingID: meetingID, todoID: todoID, done: done)
        revision += 1
    }

    /// 精准转写完成后：开了自动生成且配置好了才发送
    func autoGenerateIfEnabled(_ meetingID: UUID) {
        guard UserDefaults.standard.bool(forKey: Self.autoKey), isReady else { return }
        generate(meetingID)
    }

    func generate(_ meetingID: UUID) {
        guard let env, !generating.contains(meetingID) else { return }
        generating.insert(meetingID)
        errors[meetingID] = nil
        let service = self.service
        Task {
            defer { generating.remove(meetingID) }
            do {
                guard let meeting = try env.repository.meeting(meetingID) else { return }
                // 有精准稿用精准稿，否则用实时草稿
                let version = try env.transcripts.latestVersion(meetingID: meetingID, kind: .final)
                    ?? env.transcripts.latestVersion(meetingID: meetingID, kind: .draft)
                let segments = try version.map { try env.transcripts.segments(versionID: $0) } ?? []
                let summary = try await Summarizer(chat: try client(), contextChars: service.contextChars)
                    .summarize(meeting: meeting, segments: segments, marks: try env.repository.marks(meetingID),
                               names: try env.speakers.names(meetingID: meetingID))
                try env.summaries.save(meetingID: meetingID, summary: summary, provider: service.name, model: service.model, at: Date())
                revision += 1
                notifier.post(title: L("会议纪要已生成"), body: meeting.title, meetingID: meetingID)
            } catch SummaryError.unparseable(let raw) {
                try? env.summaries.saveFailure(meetingID: meetingID, raw: raw, error: SummaryError.unparseable(raw: raw).localizedDescription,
                                               provider: service.name, model: service.model, at: Date())
                errors[meetingID] = SummaryError.unparseable(raw: raw).localizedDescription
                revision += 1
            } catch {
                errors[meetingID] = error.localizedDescription
            }
        }
    }

    private func client() throws -> OpenAICompatibleClient {
        if let e = service.validationError { throw SummaryError.network(e) }
        guard !service.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw SummaryError.notConfigured }
        let key = try keys.read(account: service.name) ?? ""
        if service.requiresKey && key.isEmpty { throw SummaryError.notConfigured }
        return OpenAICompatibleClient(service: service, apiKey: key)
    }
}

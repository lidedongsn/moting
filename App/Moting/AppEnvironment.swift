import Foundation
import MotingASR
import MotingPipeline
import MotingRecording
import MotingStorage

/// 录音状态，供后台调度器读取（录音时会后处理让路）
final class RecordingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isRecording: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    let paths: AppPaths
    let repository: MeetingRepository
    let transcripts: TranscriptRepository
    let jobs: JobRepository
    let speakers: SpeakerRepository
    let summaries: SummaryRepository
    let modelStore: ModelStore
    let recordingFlag = RecordingFlag()
    let pipeline: PipelineRunner

    static let proxyKey = "download.proxy"
    static let offlineModelKey = "asr.offlineModel"

    private init(paths: AppPaths, db: AppDatabase) {
        self.paths = paths
        repository = MeetingRepository(db: db)
        transcripts = TranscriptRepository(db: db)
        jobs = JobRepository(db: db)
        speakers = SpeakerRepository(db: db)
        summaries = SummaryRepository(db: db)
        modelStore = ModelStore(root: paths.modelsRoot,
                                proxy: UserDefaults.standard.string(forKey: Self.proxyKey).flatMap(Self.proxyURL))
        let flag = recordingFlag
        pipeline = PipelineRunner(jobs: jobs, meetings: repository,
                                  steps: DefaultStepRunner(paths: paths, transcripts: transcripts, store: modelStore, speakers: speakers),
                                  power: SystemPowerSource(), isRecording: { flag.isRecording })
    }

    /// 打开数据库，把上次崩溃遗留的"录音中"会议与"处理中"任务收尾
    static func bootstrap() throws -> AppEnvironment {
        #if DEBUG
        // 调试版永远不碰真实数据：没指定演示目录时也用单独的目录
        let paths = AppPaths(root: DemoData.root ?? AppPaths.default.root.deletingLastPathComponent().appendingPathComponent("Moting Debug", isDirectory: true))
        #else
        let paths = AppPaths.default
        #endif
        let env = AppEnvironment(paths: paths, db: try AppDatabase.open(at: paths.databaseURL))
        #if DEBUG
        if DemoData.root != nil { try DemoData.seedIfEmpty(paths: paths, env: env) }
        #endif
        try RecordingRecovery.run(repository: env.repository, paths: paths, now: Date())
        // 下载和恢复任务开始之前清理：上次中途退出留下的临时文件；老版本写的 Cookie 现在已经用不到
        env.modelStore.cleanLeftovers()
        if let id = Bundle.main.bundleIdentifier {
            let home = FileManager.default.homeDirectoryForCurrentUser
            try? FileManager.default.removeItem(at: home.appendingPathComponent("Library/HTTPStorages/\(id)", isDirectory: true))
        }
        try env.pipeline.recoverAfterLaunch()
        return env
    }

    /// 当前选定的会后离线模型
    var offlineModel: OfflineModel {
        UserDefaults.standard.string(forKey: Self.offlineModelKey).flatMap(OfflineCatalog.model(id:)) ?? OfflineCatalog.default
    }

    func setProxy(_ text: String) {
        UserDefaults.standard.set(text, forKey: Self.proxyKey)
        modelStore.proxy = Self.proxyURL(text)
    }

    /// "127.0.0.1:7897" 或 "http://127.0.0.1:7897" 都接受；空串表示不用代理
    static func proxyURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return URL(string: t.contains("://") ? t : "http://\(t)")
    }
}

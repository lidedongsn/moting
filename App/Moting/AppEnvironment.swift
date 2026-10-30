import Foundation
import MotingASR
import MotingRecording
import MotingStorage

@MainActor
final class AppEnvironment: ObservableObject {
    let paths: AppPaths
    let repository: MeetingRepository
    let transcripts: TranscriptRepository
    let modelStore: ModelStore

    private init(paths: AppPaths, db: AppDatabase) {
        self.paths = paths
        repository = MeetingRepository(db: db)
        transcripts = TranscriptRepository(db: db)
        modelStore = ModelStore(root: paths.modelsRoot)
    }

    /// 打开数据库，并把上次崩溃遗留的"录音中"会议收尾
    static func bootstrap() throws -> AppEnvironment {
        let paths = AppPaths.default
        let env = AppEnvironment(paths: paths, db: try AppDatabase.open(at: paths.databaseURL))
        try RecordingRecovery.run(repository: env.repository, paths: paths, now: Date())
        return env
    }
}

import Foundation
import MotingRecording
import MotingStorage

@MainActor
final class AppEnvironment: ObservableObject {
    let paths: AppPaths
    let repository: MeetingRepository

    private init(paths: AppPaths, repository: MeetingRepository) {
        self.paths = paths
        self.repository = repository
    }

    /// 打开数据库，并把上次崩溃遗留的"录音中"会议收尾
    static func bootstrap() throws -> AppEnvironment {
        let paths = AppPaths.default
        let repository = MeetingRepository(db: try AppDatabase.open(at: paths.databaseURL))
        try RecordingRecovery.run(repository: repository, paths: paths, now: Date())
        return AppEnvironment(paths: paths, repository: repository)
    }
}

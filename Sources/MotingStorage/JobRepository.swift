import Foundation
import GRDB
import MotingCore

struct JobRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "job"
    var id: String
    var meetingId: String
    var status: String
    var completedSteps: String
    var progress: Double
    var error: String?
    var modelId: String
    var versionId: String?
    var filterOutcome: String?
    var createdAt: Date
    var interruptions: Int

    init(_ j: Job) {
        id = j.id.uuidString
        meetingId = j.meetingID.uuidString
        status = j.status.rawValue
        completedSteps = j.completedSteps.map(\.rawValue).joined(separator: ",")
        progress = j.progress
        error = j.error
        modelId = j.modelID
        versionId = j.versionID?.uuidString
        filterOutcome = j.filterOutcome
        createdAt = j.createdAt
        interruptions = j.interruptions
    }

    var model: Job? {
        guard let id = UUID(uuidString: id), let meeting = UUID(uuidString: meetingId) else { return nil }
        var job = Job(id: id, meetingID: meeting, status: JobStatus(rawValue: status) ?? .failed,
                      completedSteps: completedSteps.split(separator: ",").compactMap { JobStep(rawValue: String($0)) },
                      progress: progress, error: error, modelID: modelId,
                      versionID: versionId.flatMap(UUID.init(uuidString:)), filterOutcome: filterOutcome, createdAt: createdAt)
        job.interruptions = interruptions
        return job
    }
}

public final class JobRepository: Sendable {
    private let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    /// 同一会议已有未完成（非 done / failed）的任务时返回那个，否则新建
    public func enqueue(meetingID: UUID, modelID: String, status: JobStatus, at: Date) throws -> Job {
        try db.writer.write { db in
            if let existing = try JobRecord
                .filter(Column("meetingId") == meetingID.uuidString)
                .filter(![JobStatus.done.rawValue, JobStatus.failed.rawValue].contains(Column("status")))
                .fetchOne(db)?.model {
                return existing
            }
            let job = Job(meetingID: meetingID, status: status, modelID: modelID, createdAt: at)
            try JobRecord(job).insert(db)
            return job
        }
    }

    /// 最早的 queued 任务（不含等待插电的）
    public func next() throws -> Job? {
        try db.writer.read { db in
            try JobRecord.filter(Column("status") == JobStatus.queued.rawValue).order(Column("createdAt")).fetchOne(db)?.model
        }
    }

    public func update(_ job: Job) throws {
        try db.writer.write { db in try JobRecord(job).update(db) }
    }

    /// 该会议最新的任务
    public func job(for meetingID: UUID) throws -> Job? {
        try db.writer.read { db in
            try JobRecord.filter(Column("meetingId") == meetingID.uuidString).order(Column("createdAt").desc).fetchOne(db)?.model
        }
    }

    public func jobs(status: JobStatus) throws -> [Job] {
        try db.writer.read { db in
            try JobRecord.filter(Column("status") == status.rawValue).order(Column("createdAt")).fetchAll(db).compactMap(\.model)
        }
    }

    /// 连续中断这么多次就不再自动重试
    static let maxInterruptions = 2

    /// app 启动时调用：上次退出时还在跑的任务改回排队，已完成的步骤保留；返回改回排队的个数。
    /// 识别库可能直接退出进程，走不到错误处理：同一步反复中断就标记失败，否则就是打开 app 就退
    @discardableResult
    public func requeueStaleRunning() throws -> Int {
        try db.writer.write { db in
            var requeued = 0
            for record in try JobRecord.filter(Column("status") == JobStatus.running.rawValue).fetchAll(db) {
                var r = record
                r.interruptions += 1
                if r.interruptions >= Self.maxInterruptions {
                    r.status = JobStatus.failed.rawValue
                    r.error = L("精准转写反复意外中断，已停止自动重试。可以在设置里换一个识别模型后再试。")
                    try db.execute(sql: "UPDATE meeting SET status = ? WHERE id = ?",
                                   arguments: [MeetingStatus.failed.rawValue, r.meetingId])
                } else {
                    r.status = JobStatus.queued.rawValue
                    requeued += 1
                }
                try r.update(db)
            }
            return requeued
        }
    }

    public func observe(meetingID: UUID) -> AsyncValueObservation<Job?> {
        ValueObservation
            .tracking { db in
                try JobRecord.filter(Column("meetingId") == meetingID.uuidString)
                    .order(Column("createdAt").desc).fetchOne(db)?.model
            }
            .values(in: db.writer)
    }
}

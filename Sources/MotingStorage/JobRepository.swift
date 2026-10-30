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
    }

    var model: Job? {
        guard let id = UUID(uuidString: id), let meeting = UUID(uuidString: meetingId) else { return nil }
        return Job(id: id, meetingID: meeting, status: JobStatus(rawValue: status) ?? .failed,
                   completedSteps: completedSteps.split(separator: ",").compactMap { JobStep(rawValue: String($0)) },
                   progress: progress, error: error, modelID: modelId,
                   versionID: versionId.flatMap(UUID.init(uuidString:)), filterOutcome: filterOutcome, createdAt: createdAt)
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

    /// app 启动时调用：上次退出时还在跑的任务改回排队，已完成的步骤保留
    @discardableResult
    public func requeueStaleRunning() throws -> Int {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE job SET status = ? WHERE status = ?",
                           arguments: [JobStatus.queued.rawValue, JobStatus.running.rawValue])
            return db.changesCount
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

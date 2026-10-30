import Foundation
import GRDB
import MotingCore

struct TranscriptVersionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcriptVersion"
    var id: String
    var meetingId: String
    var kind: String
    var engine: String
    var model: String
    var createdAt: Date
}

struct SegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "segment"
    var id: String
    var versionId: String
    var channel: String
    var speakerLabel: String?
    var start: Double
    var end: Double
    var text: String
}

public final class TranscriptRepository: Sendable {
    private let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    /// 每次调用新建一个版本，返回版本 id
    public func createVersion(meetingID: UUID, kind: TranscriptKind, engine: String, model: String,
                              createdAt: Date) throws -> UUID {
        let id = UUID()
        try db.writer.write { db in
            try TranscriptVersionRecord(id: id.uuidString, meetingId: meetingID.uuidString, kind: kind.rawValue,
                                        engine: engine, model: model, createdAt: createdAt).insert(db)
        }
        return id
    }

    public func append(_ s: TranscriptSegment) throws {
        try db.writer.write { db in
            try SegmentRecord(id: s.id.uuidString, versionId: s.versionID.uuidString, channel: s.channel.rawValue,
                              speakerLabel: s.speakerLabel, start: s.start, end: s.end, text: s.text).insert(db)
        }
    }

    public func latestVersion(meetingID: UUID, kind: TranscriptKind) throws -> UUID? {
        try db.writer.read { db in
            try TranscriptVersionRecord
                .filter(Column("meetingId") == meetingID.uuidString && Column("kind") == kind.rawValue)
                .order(Column("createdAt").desc)
                .fetchOne(db)
                .flatMap { UUID(uuidString: $0.id) }
        }
    }

    public func segments(versionID: UUID) throws -> [TranscriptSegment] {
        try db.writer.read { db in
            try SegmentRecord.filter(Column("versionId") == versionID.uuidString).order(Column("start")).fetchAll(db)
                .compactMap { r in
                    guard let id = UUID(uuidString: r.id), let ch = AudioChannel(rawValue: r.channel) else { return nil }
                    return TranscriptSegment(id: id, versionID: versionID, channel: ch, speakerLabel: r.speakerLabel,
                                             start: r.start, end: r.end, text: r.text)
                }
        }
    }
}

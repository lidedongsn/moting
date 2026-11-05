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
    /// 正式稿处理完成的时间；未完成的正式稿不对外显示
    var completedAt: Date?
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
    var originalText: String?
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
                                        engine: engine, model: model, createdAt: createdAt, completedAt: nil).insert(db)
        }
        return id
    }

    public func append(_ s: TranscriptSegment) throws {
        try db.writer.write { db in
            try SegmentRecord(id: s.id.uuidString, versionId: s.versionID.uuidString, channel: s.channel.rawValue,
                              speakerLabel: s.speakerLabel, start: s.start, end: s.end, text: s.text,
                              originalText: s.originalText).insert(db)
        }
    }

    /// 最新版本；正式稿只算已完成的（处理中的半成品不显示）
    public func latestVersion(meetingID: UUID, kind: TranscriptKind) throws -> UUID? {
        try db.writer.read { db in
            var q = TranscriptVersionRecord
                .filter(Column("meetingId") == meetingID.uuidString && Column("kind") == kind.rawValue)
            if kind == .final { q = q.filter(Column("completedAt") != nil) }
            return try q
                .order(Column("createdAt").desc)
                .fetchOne(db)
                .flatMap { UUID(uuidString: $0.id) }
        }
    }

    public func markCompleted(_ versionID: UUID, at: Date) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE transcriptVersion SET completedAt = ? WHERE id = ?", arguments: [at, versionID.uuidString])
        }
    }

    public func isCompleted(_ versionID: UUID) throws -> Bool {
        try db.writer.read { db in
            try TranscriptVersionRecord.fetchOne(db, key: versionID.uuidString)?.completedAt != nil
        }
    }

    /// 删除版本，片段随外键级联删除
    /// 删掉这场会议没完成的正式稿（转写中途暂停 / 退出留下的半成品），片段随外键删除
    public func deleteIncompleteFinalVersions(meetingID: UUID) throws {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM transcriptVersion WHERE meetingId = ? AND kind = ? AND completedAt IS NULL",
                           arguments: [meetingID.uuidString, TranscriptKind.final.rawValue])
        }
    }

    /// 版本属于哪场会议
    public func meetingID(ofVersion versionID: UUID) throws -> UUID? {
        try db.writer.read { db in
            try TranscriptVersionRecord.fetchOne(db, key: versionID.uuidString).flatMap { UUID(uuidString: $0.meetingId) }
        }
    }

    public func deleteVersion(_ versionID: UUID) throws {
        try db.writer.write { db in
            _ = try TranscriptVersionRecord.deleteOne(db, key: versionID.uuidString)
        }
    }

    public func setSpeakerLabel(_ segmentID: UUID, label: String?) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE segment SET speakerLabel = ? WHERE id = ?", arguments: [label, segmentID.uuidString])
        }
    }

    // MARK: - 手动编辑

    /// 改一句话。第一次改时保存识别的原文；改回原文就不算改过；空白内容忽略，避免一句话被误删
    public func setText(segmentID: UUID, text: String) throws {
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { return }
        try db.writer.write { db in
            guard var r = try SegmentRecord.fetchOne(db, key: segmentID.uuidString), r.text != new else { return }
            let original = r.originalText ?? r.text
            r.text = new
            r.originalText = new == original ? nil : original
            try r.update(db)
        }
    }

    /// 恢复成识别的原文
    public func restoreText(segmentID: UUID) throws {
        try db.writer.write { db in
            guard var r = try SegmentRecord.fetchOne(db, key: segmentID.uuidString), let original = r.originalText else { return }
            r.text = original
            r.originalText = nil
            try r.update(db)
        }
    }

    /// 整句删掉：文字清空、原文留着，可以恢复；读取时不再返回
    public func removeSegment(_ segmentID: UUID) throws {
        try db.writer.write { db in
            guard var r = try SegmentRecord.fetchOne(db, key: segmentID.uuidString) else { return }
            r.originalText = r.originalText ?? r.text
            r.text = ""
            try r.update(db)
        }
    }

    /// 恢复这份转写稿所有改过和删掉的句子
    public func restoreAll(versionID: UUID) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE segment SET text = originalText, originalText = NULL WHERE versionId = ? AND originalText IS NOT NULL",
                           arguments: [versionID.uuidString])
        }
    }

    public func hasEdits(versionID: UUID) throws -> Bool {
        try db.writer.read { db in
            try SegmentRecord.filter(Column("versionId") == versionID.uuidString && Column("originalText") != nil).fetchCount(db) > 0
        }
    }

    /// 这场会议当前的正式稿有没有手动修改：重新转写会把它们覆盖掉，要先提醒
    public func finalTranscriptHasEdits(meetingID: UUID) throws -> Bool {
        guard let version = try latestVersion(meetingID: meetingID, kind: .final) else { return false }
        return try hasEdits(versionID: version)
    }

    public func deleteSegments(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try db.writer.write { db in
            _ = try SegmentRecord.deleteAll(db, keys: ids.map(\.uuidString))
        }
    }

    /// 任意版本的转写文字包含 text 的会议（% 与 _ 按普通字符处理）
    public func meetingIDs(matching text: String) throws -> Set<UUID> {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        let escaped = t.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try db.writer.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT DISTINCT v.meetingId FROM segment s JOIN transcriptVersion v ON s.versionId = v.id
                WHERE s.text LIKE ? ESCAPE '\\'
                """, arguments: ["%\(escaped)%"])
            return Set(ids.compactMap(UUID.init(uuidString:)))
        }
    }

    public func segments(versionID: UUID) throws -> [TranscriptSegment] {
        try db.writer.read { db in
            try SegmentRecord.filter(Column("versionId") == versionID.uuidString && Column("text") != "").order(Column("start")).fetchAll(db)
                .compactMap { r in
                    guard let id = UUID(uuidString: r.id), let ch = AudioChannel(rawValue: r.channel) else { return nil }
                    var s = TranscriptSegment(id: id, versionID: versionID, channel: ch, speakerLabel: r.speakerLabel,
                                              start: r.start, end: r.end, text: r.text)
                    s.originalText = r.originalText
                    return s
                }
        }
    }
}

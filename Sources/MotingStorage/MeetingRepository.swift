import Foundation
import GRDB
import MotingCore

public struct AudioTrackInfo: Codable, Sendable, Equatable {
    public var meetingID: UUID
    public var channel: AudioChannel
    public var relativePath: String
    public var sampleRate: Int

    public init(meetingID: UUID, channel: AudioChannel, relativePath: String, sampleRate: Int) {
        self.meetingID = meetingID
        self.channel = channel
        self.relativePath = relativePath
        self.sampleRate = sampleRate
    }
}

public final class MeetingRepository: Sendable {
    let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    public func insert(_ m: Meeting, tracks: [AudioTrackInfo]) throws {
        try db.writer.write { db in
            try MeetingRecord(m).insert(db)
            for t in tracks {
                try AudioTrackRecord(id: nil, meetingId: t.meetingID.uuidString, channel: t.channel.rawValue,
                                     relativePath: t.relativePath, sampleRate: t.sampleRate).insert(db)
            }
        }
    }

    public func setStatus(_ id: UUID, _ status: MeetingStatus, endedAt: Date?) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE meeting SET status = ?, endedAt = ? WHERE id = ?",
                           arguments: [status.rawValue, endedAt, id.uuidString])
        }
    }

    /// 只改状态，不动结束时间（会后处理用）
    public func updateStatus(_ id: UUID, _ status: MeetingStatus) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE meeting SET status = ? WHERE id = ?", arguments: [status.rawValue, id.uuidString])
        }
    }

    /// 去掉首尾空白后为空则不改
    public func rename(_ id: UUID, to title: String) throws {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try db.writer.write { db in
            try db.execute(sql: "UPDATE meeting SET title = ? WHERE id = ?", arguments: [t, id.uuidString])
        }
    }

    public func addMark(_ mark: Mark) throws {
        try db.writer.write { db in
            try MarkRecord(id: mark.id.uuidString, meetingId: mark.meetingID.uuidString, at: mark.at).insert(db)
        }
    }

    public func beginPause(meetingID: UUID, at: Date) throws {
        try db.writer.write { db in
            try PauseRecord(id: nil, meetingId: meetingID.uuidString, startedAt: at, endedAt: nil).insert(db)
        }
    }

    /// 关闭该会议所有未结束的暂停；没有则什么都不做
    public func endOpenPause(meetingID: UUID, at: Date) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE pause SET endedAt = ? WHERE meetingId = ? AND endedAt IS NULL",
                           arguments: [at, meetingID.uuidString])
        }
    }

    /// 删除会议记录，音轨 / 标记 / 暂停随外键级联删除。录音文件由调用方删除
    public func delete(_ id: UUID) throws {
        _ = try db.writer.write { db in try MeetingRecord.deleteOne(db, key: id.uuidString) }
    }

    public func meeting(_ id: UUID) throws -> Meeting? {
        try db.writer.read { db in try MeetingRecord.fetchOne(db, key: id.uuidString)?.model }
    }

    public func marks(_ id: UUID) throws -> [Mark] {
        try db.writer.read { db in
            try MarkRecord.filter(Column("meetingId") == id.uuidString).order(Column("at")).fetchAll(db)
                .map { Mark(id: UUID(uuidString: $0.id)!, meetingID: id, at: $0.at) }
        }
    }

    public func tracks(_ id: UUID) throws -> [AudioTrackInfo] {
        try db.writer.read { db in
            try AudioTrackRecord.filter(Column("meetingId") == id.uuidString).fetchAll(db).compactMap { r in
                AudioChannel(rawValue: r.channel).map {
                    AudioTrackInfo(meetingID: id, channel: $0, relativePath: r.relativePath, sampleRate: r.sampleRate)
                }
            }
        }
    }

    public func pauses(_ id: UUID) throws -> [(start: Date, end: Date?)] {
        try db.writer.read { db in
            try PauseRecord.filter(Column("meetingId") == id.uuidString).order(Column("startedAt")).fetchAll(db)
                .map { ($0.startedAt, $0.endedAt) }
        }
    }

    public func meetings(status: MeetingStatus) throws -> [Meeting] {
        try db.writer.read { db in
            try MeetingRecord.filter(Column("status") == status.rawValue).order(Column("startedAt").desc)
                .fetchAll(db).map(\.model)
        }
    }

    /// 全部会议，按开始时间倒序；数据变化时推送新值
    public func observeAll() -> AsyncValueObservation<[Meeting]> {
        ValueObservation
            .tracking { db in try MeetingRecord.order(Column("startedAt").desc).fetchAll(db).map(\.model) }
            .values(in: db.writer)
    }
}

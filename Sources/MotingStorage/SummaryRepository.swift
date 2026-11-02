import Foundation
import GRDB
import MotingCore

/// 存下来的 AI 纪要；解析失败时 summary 为 nil，raw 是模型原文
public struct StoredSummary: Sendable, Equatable {
    public var summary: MeetingSummary?
    public var raw: String?
    public var error: String?
    public var provider: String
    public var model: String
    public var createdAt: Date
}

/// AI 纪要：每场会议一份，重新生成时覆盖，随会议删除
public final class SummaryRepository: Sendable {
    private let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    public func save(meetingID: UUID, summary: MeetingSummary, provider: String, model: String, at: Date) throws {
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        try upsert(meetingID, json: json, raw: nil, error: nil, provider: provider, model: model, at: at)
    }

    public func saveFailure(meetingID: UUID, raw: String?, error: String, provider: String, model: String, at: Date) throws {
        try upsert(meetingID, json: nil, raw: raw, error: error, provider: provider, model: model, at: at)
    }

    public func load(meetingID: UUID) throws -> StoredSummary? {
        try db.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM summary WHERE meetingId = ?",
                                             arguments: [meetingID.uuidString]) else { return nil }
            let json: String? = row["json"]
            return StoredSummary(summary: json.flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: Data($0.utf8)) },
                                 raw: row["raw"], error: row["error"], provider: row["provider"], model: row["model"],
                                 createdAt: row["createdAt"])
        }
    }

    /// 勾选 / 取消待办
    public func setTodo(meetingID: UUID, todoID: UUID, done: Bool) throws {
        guard let stored = try load(meetingID: meetingID), var summary = stored.summary,
              let i = summary.todos.firstIndex(where: { $0.id == todoID }) else { return }
        summary.todos[i].done = done
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        try db.writer.write { db in
            try db.execute(sql: "UPDATE summary SET json = ? WHERE meetingId = ?", arguments: [json, meetingID.uuidString])
        }
    }

    private func upsert(_ id: UUID, json: String?, raw: String?, error: String?, provider: String, model: String, at: Date) throws {
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO summary (meetingId, json, raw, error, provider, model, createdAt) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(meetingId) DO UPDATE SET json = excluded.json, raw = excluded.raw, error = excluded.error,
                    provider = excluded.provider, model = excluded.model, createdAt = excluded.createdAt
                """, arguments: [id.uuidString, json, raw, error, provider, model, at])
        }
    }
}

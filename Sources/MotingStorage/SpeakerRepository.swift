import Foundation
import GRDB

/// 说话人显示名：把"说话人 1"等标签改成真名
public final class SpeakerRepository: Sendable {
    private let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    /// 去掉首尾空白后为空 = 恢复默认（删除记录）
    public func setName(meetingID: UUID, label: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.writer.write { db in
            if trimmed.isEmpty {
                try db.execute(sql: "DELETE FROM speaker WHERE meetingId = ? AND label = ?",
                               arguments: [meetingID.uuidString, label])
            } else {
                try db.execute(sql: """
                    INSERT INTO speaker (meetingId, label, displayName) VALUES (?, ?, ?)
                    ON CONFLICT(meetingId, label) DO UPDATE SET displayName = excluded.displayName
                    """, arguments: [meetingID.uuidString, label, trimmed])
            }
        }
    }

    /// 清空这场会议的改名（重新分离后编号会变，旧名字对不上人）
    public func removeAll(meetingID: UUID) throws {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM speaker WHERE meetingId = ?", arguments: [meetingID.uuidString])
        }
    }

    /// label → 显示名
    public func names(meetingID: UUID) throws -> [String: String] {
        try db.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT label, displayName FROM speaker WHERE meetingId = ?",
                                        arguments: [meetingID.uuidString])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["label"] as String, $0["displayName"] as String) })
        }
    }
}

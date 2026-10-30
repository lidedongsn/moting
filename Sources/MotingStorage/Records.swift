import Foundation
import GRDB
import MotingCore

// 内部 GRDB 记录类型，对外只暴露 MotingCore 模型

struct MeetingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meeting"
    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var status: String

    init(_ m: Meeting) {
        id = m.id.uuidString
        title = m.title
        startedAt = m.startedAt
        endedAt = m.endedAt
        status = m.status.rawValue
    }

    var model: Meeting {
        Meeting(id: UUID(uuidString: id)!, title: title, startedAt: startedAt, endedAt: endedAt,
                status: MeetingStatus(rawValue: status) ?? .failed)
    }
}

struct AudioTrackRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "audioTrack"
    var id: Int64?
    var meetingId: String
    var channel: String
    var relativePath: String
    var sampleRate: Int
}

struct MarkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mark"
    var id: String
    var meetingId: String
    var at: Double
}

struct PauseRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pause"
    var id: Int64?
    var meetingId: String
    var startedAt: Date
    var endedAt: Date?
}

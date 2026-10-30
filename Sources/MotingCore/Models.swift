import Foundation

/// 音频来源：麦克风 = 我，系统音频 = 对方
public enum AudioChannel: String, Codable, Sendable, CaseIterable {
    case mic, system
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording, pendingProcessing, interrupted, processing, done, failed
}

public struct Meeting: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus

    public init(id: UUID, title: String, startedAt: Date, endedAt: Date?, status: MeetingStatus) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
    }

    /// 新建一场录音中的会议，标题为"会议 yyyy-MM-dd HH:mm"（本地时区）
    public static func new(startedAt: Date) -> Meeting {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return Meeting(id: UUID(), title: "会议 \(f.string(from: startedAt))",
                       startedAt: startedAt, endedAt: nil, status: .recording)
    }
}

/// 会中标记的重点
public struct Mark: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var meetingID: UUID
    /// 会议时间（去掉暂停后），秒
    public var at: TimeInterval

    public init(id: UUID = UUID(), meetingID: UUID, at: TimeInterval) {
        self.id = id
        self.meetingID = meetingID
        self.at = at
    }
}

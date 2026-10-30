import Foundation

/// draft：会中实时识别的草稿；final：会后精准重识别的正式稿
public enum TranscriptKind: String, Codable, Sendable {
    case draft, final
}

public struct TranscriptSegment: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var versionID: UUID
    public var channel: AudioChannel
    /// 说话人标签（P3 说话人分离后填写）
    public var speakerLabel: String?
    /// 会议时间（去掉暂停），秒
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(id: UUID = UUID(), versionID: UUID, channel: AudioChannel, speakerLabel: String? = nil,
                start: TimeInterval, end: TimeInterval, text: String) {
        self.id = id
        self.versionID = versionID
        self.channel = channel
        self.speakerLabel = speakerLabel
        self.start = start
        self.end = end
        self.text = text
    }
}

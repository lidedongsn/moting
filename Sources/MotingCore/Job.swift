import Foundation

/// 会后处理步骤，声明顺序即执行顺序
public enum JobStep: String, Codable, Sendable, CaseIterable {
    case transcribe, diarize, filterVoice, merge
}

public enum JobStatus: String, Codable, Sendable {
    case queued, waitingForPower, running, done, failed
}

/// 一场会议的会后处理任务（持久化，可断点续跑）
public struct Job: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var meetingID: UUID
    public var status: JobStatus
    public var completedSteps: [JobStep]
    /// 0–1，整体进度
    public var progress: Double
    public var error: String?
    /// 本次使用的离线模型
    public var modelID: String
    /// 转写步骤生成的正式稿版本
    public var versionID: UUID?
    /// 声纹过滤结果（filtered / skippedNoVoiceprint / fellBack）
    public var filterOutcome: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), meetingID: UUID, status: JobStatus, completedSteps: [JobStep] = [],
                progress: Double = 0, error: String? = nil, modelID: String, versionID: UUID? = nil,
                filterOutcome: String? = nil, createdAt: Date) {
        self.id = id
        self.meetingID = meetingID
        self.status = status
        self.completedSteps = completedSteps
        self.progress = progress
        self.error = error
        self.modelID = modelID
        self.versionID = versionID
        self.filterOutcome = filterOutcome
        self.createdAt = createdAt
    }
}

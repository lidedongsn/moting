import Foundation

/// 会议时钟：累计去掉暂停后的录音时长。纯值类型，时间由调用方传入，便于测试
public struct MeetingClock: Sendable {
    private var accumulated: TimeInterval = 0
    private var runningSince: Date?

    public init() {}

    public var isPaused: Bool { runningSince == nil }

    public mutating func start(at date: Date) {
        accumulated = 0
        runningSince = date
    }

    public mutating func pause(at date: Date) {
        guard let since = runningSince else { return }
        accumulated += date.timeIntervalSince(since)
        runningSince = nil
    }

    public mutating func resume(at date: Date) {
        guard runningSince == nil else { return }
        runningSince = date
    }

    public func elapsed(at date: Date) -> TimeInterval {
        guard let since = runningSince else { return accumulated }
        return accumulated + date.timeIntervalSince(since)
    }
}

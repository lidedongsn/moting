import Foundation
import MotingCapture

public enum ChannelStatus: Sendable, Equatable {
    case ok
    /// 开录以来一直是数字静音（全 0）：系统音频多半是没有录制权限
    case silent
    /// 超过 3 秒没收到任何数据
    case stalled
    case interrupted(String)
}

/// 单路音频的健康状态，纯逻辑；时间为开录后的秒数，由调用方传入
public struct ChannelHealth: Sendable {
    private let silenceWarning: TimeInterval
    private let stallTimeout: TimeInterval
    private var heardSound = false
    private var lastChunkAt: TimeInterval?
    private var interruption: String?

    public init(silenceWarning: TimeInterval = 10, stallTimeout: TimeInterval = 3) {
        self.silenceWarning = silenceWarning
        self.stallTimeout = stallTimeout
    }

    public mutating func record(_ event: AudioSourceEvent, at t: TimeInterval) {
        switch event {
        case .chunk(let c):
            lastChunkAt = t
            if c.level > 0 { heardSound = true }
        case .interrupted(let reason):
            interruption = reason
        case .resumed:
            interruption = nil
            lastChunkAt = t
        }
    }

    public func status(at t: TimeInterval) -> ChannelStatus {
        if let interruption { return .interrupted(interruption) }
        if let last = lastChunkAt, t - last > stallTimeout { return .stalled }
        if !heardSound, t >= silenceWarning { return .silent }
        return .ok
    }
}

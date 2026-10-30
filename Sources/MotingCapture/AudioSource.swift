import Foundation
import MotingCore

public struct AudioChunk: Sendable {
    /// 16kHz 单声道
    public var samples: [Float]
    /// 本块 RMS，供 UI 电平显示
    public var level: Float

    public init(samples: [Float], level: Float) {
        self.samples = samples
        self.level = level
    }
}

public enum AudioSourceEvent: Sendable {
    case chunk(AudioChunk)
    /// 设备消失等情况，源会自行尝试恢复
    case interrupted(String)
    case resumed
}

public protocol AudioSource: AnyObject {
    var channel: AudioChannel { get }
    /// handler 在源内部的串行消费队列上调用，绝不在实时线程
    func start(handler: @escaping @Sendable (AudioSourceEvent) -> Void) throws
    func stop()
}

public enum CaptureError: Error, Equatable {
    case permissionDenied(AudioChannel)
    case deviceUnavailable(String)
    case coreAudio(OSStatus, String)
}

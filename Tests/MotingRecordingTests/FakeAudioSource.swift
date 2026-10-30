import Foundation
import MotingCapture
import MotingCore

final class FakeAudioSource: AudioSource, @unchecked Sendable {
    let channel: AudioChannel
    var startError: Error?
    private(set) var stopCount = 0
    private var handler: (@Sendable (AudioSourceEvent) -> Void)?

    init(_ channel: AudioChannel) {
        self.channel = channel
    }

    func start(handler: @escaping @Sendable (AudioSourceEvent) -> Void) throws {
        if let startError { throw startError }
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ event: AudioSourceEvent) {
        handler?(event)
    }

    func emitSamples(_ n: Int) {
        emit(.chunk(AudioChunk(samples: [Float](repeating: 0.1, count: n), level: 0.1)))
    }
}

/// 测试可控的时钟
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

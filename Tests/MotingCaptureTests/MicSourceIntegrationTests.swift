import Foundation
import Testing
@testable import MotingCapture

/// 需要真实麦克风与授权，仅在 MOTING_AUDIO_IT=1 时运行
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_AUDIO_IT"] == "1"))
func micDeliversChunks() async throws {
    let counter = SampleCounter()
    let mic = MicSource()
    try mic.start { event in
        if case .chunk(let c) = event { counter.add(c.samples.count, level: c.level) }
    }
    try await Task.sleep(for: .seconds(2))
    mic.stop()
    let (n, peak) = counter.snapshot()
    print("mic 采样数 \(n)，最大电平 \(peak)")
    #expect(abs(n - 32_000) <= 3_200)
}

final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var peak: Float = 0
    func add(_ n: Int, level: Float) {
        lock.lock(); count += n; peak = max(peak, level); lock.unlock()
    }
    func snapshot() -> (Int, Float) {
        lock.lock(); defer { lock.unlock() }
        return (count, peak)
    }
}

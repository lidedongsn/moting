import Foundation
import Testing
@testable import MotingCapture

/// 需要系统音频录制授权，仅在 MOTING_AUDIO_IT=1 时运行
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_AUDIO_IT"] == "1"))
func tapCapturesPlayback() async throws {
    let counter = SampleCounter()
    let tap = SystemAudioTapSource()
    try tap.start { event in
        if case .chunk(let c) = event { counter.add(c.samples.count, level: c.level) }
    }
    let player = Process()
    player.executableURL = URL(fileURLWithPath: "/bin/sh")
    player.arguments = ["-c", "for i in 1 2 3; do afplay /System/Library/Sounds/Submarine.aiff; done"]
    try player.run()
    try await Task.sleep(for: .seconds(3))
    tap.stop()
    player.terminate()
    let (n, peak) = counter.snapshot()
    print("tap 采样数 \(n)，最大电平 \(peak)")
    #expect(peak > 0.01)
}

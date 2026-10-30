import Foundation
import Testing
import MotingCapture
import MotingCore
import MotingStorage
@testable import MotingRecording

/// 真实设备上的开始 → 结束，仅在 MOTING_AUDIO_IT=1 时运行
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_AUDIO_IT"] == "1"), .timeLimit(.minutes(1)))
func realSessionStopsCleanly() async throws {
    let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let repo = MeetingRepository(db: try AppDatabase.inMemory())
    let session = RecordingSession(paths: paths, repository: repo, sources: [MicSource(), SystemAudioTapSource()])
    let m = try session.start()
    try await Task.sleep(for: .seconds(2))
    let flag = StopFlag()
    let t0 = Date()
    Thread {
        try? session.stop()
        flag.set()
    }.start()
    for _ in 0..<50 where !flag.value { try await Task.sleep(for: .milliseconds(100)) }
    let finished = flag.value
    print("stop() 耗时 \(String(format: "%.2f", Date().timeIntervalSince(t0))) 秒")
    #expect(Date().timeIntervalSince(t0) < 1.5, "结束录音应在 1.5 秒内完成")
    #expect(finished, "stop() 5 秒内没有返回")
    if finished { #expect(try repo.meeting(m.id)?.status == .pendingProcessing) }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.withLock { v } }
    func set() { lock.withLock { v = true } }
}

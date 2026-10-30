import Foundation
import Testing
import MotingCapture
@testable import MotingPlayback

/// 真实走一遍 AVAudioEngine 播放（音量 0），直到播完。
/// 回归：缓冲完成回调在 AVAudioPlayerNode 自己的队列上被调用，曾因被推断为 @MainActor 而崩溃
@MainActor
@Test(.timeLimit(.minutes(1)))
func playsToEndWithoutCrashing() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moting-play-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var urls: [URL] = []
    for name in ["mic", "system"] {
        let url = dir.appendingPathComponent("\(name).pcm")
        let w = try PCMTrackWriter(url: url)
        try w.append((0..<16_000).map { Float(sin(Double($0) * 0.1)) * 0.1 })   // 1 秒
        try w.close()
        urls.append(url)
    }
    let player = MeetingPlayer(urls: urls, volume: 0)
    #expect(abs(player.duration - 1) < 0.01)
    player.play()
    #expect(player.isPlaying)
    for _ in 0..<50 where player.isPlaying {
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(!player.isPlaying)
    #expect(abs(player.currentTime - player.duration) < 0.01)
    player.close()
}

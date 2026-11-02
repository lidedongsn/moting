import Foundation
import Testing
import MotingCapture
@testable import MotingPlayback

@Test func playedFramesMapBackToSourceAcrossSkippedSilence() {
    // 排了 0–8000，跳过 8000–40000 的静音，再排 40000–48000
    var m = PlaybackMap()
    m.scheduled(source: 0, count: 8_000)
    m.scheduled(source: 40_000, count: 8_000)
    #expect(m.source(forPlayed: 0) == 0)
    #expect(m.source(forPlayed: 7_999) == 7_999)
    #expect(m.source(forPlayed: 8_000) == 40_000)
    #expect(m.source(forPlayed: 9_000) == 41_000)
    #expect(m.source(forPlayed: 20_000) == 48_000, "超出已排部分时停在最后一段末尾")
}

@Test func silentChunkDetection() {
    #expect(MeetingPlayer.isSilent([Float](repeating: 0.001, count: 8_000)))
    #expect(!MeetingPlayer.isSilent((0..<8_000).map { Float(sin(Double($0) * 0.1)) * 0.1 }))
}

private func makeTracks(_ samples: [Float]) throws -> (URL, [URL]) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moting-play-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var urls: [URL] = []
    for name in ["mic", "system"] {
        let url = dir.appendingPathComponent("\(name).pcm")
        let w = try PCMTrackWriter(url: url)
        try w.append(samples)
        try w.close()
        urls.append(url)
    }
    return (dir, urls)
}

/// 播到结束，返回用时；音频输出不可用时返回 nil
@MainActor
private func playToEnd(_ player: MeetingPlayer) async throws -> TimeInterval? {
    let t0 = Date()
    player.play()
    if player.lastError != nil { return nil }
    for _ in 0..<100 where player.isPlaying { try await Task.sleep(for: .milliseconds(50)) }
    return Date().timeIntervalSince(t0)
}

private let tone = (0..<16_000).map { Float(sin(Double($0) * 0.1)) * 0.1 }

@MainActor
@Test(.timeLimit(.minutes(1)))
func doubleSpeedFinishesInAboutHalfTheTime() async throws {
    let (dir, urls) = try makeTracks(tone + tone + tone)          // 3 秒
    defer { try? FileManager.default.removeItem(at: dir) }
    let player = MeetingPlayer(urls: urls, volume: 0)
    player.rate = 2
    guard let took = try await playToEnd(player) else { return }
    #expect(took < 2.3, "2 倍速播 3 秒用了 \(took) 秒")
    #expect(abs(player.currentTime - player.duration) < 0.01)
    player.close()
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func skipSilenceJumpsOverLongPauses() async throws {
    let silence = [Float](repeating: 0, count: 4 * 16_000)
    let (dir, urls) = try makeTracks(tone + silence + tone)       // 1 秒声音 + 4 秒静音 + 1 秒声音
    defer { try? FileManager.default.removeItem(at: dir) }
    let player = MeetingPlayer(urls: urls, volume: 0)
    player.skipSilence = true
    guard let took = try await playToEnd(player) else { return }
    #expect(took < 3.5, "跳过静音后仍用了 \(took) 秒")
    #expect(abs(player.currentTime - player.duration) < 0.01)
    player.close()
}

import Foundation
import Testing
import MotingCapture
import MotingCore
import MotingStorage
@testable import MotingRecording

private final class Fixture {
    let clock = TestClock()
    let mic = FakeAudioSource(.mic)
    let system = FakeAudioSource(.system)
    let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let repo: MeetingRepository
    let session: RecordingSession

    init() throws {
        repo = MeetingRepository(db: try AppDatabase.inMemory())
        let clock = clock
        session = RecordingSession(paths: paths, repository: repo, sources: [mic, system], now: { clock.now })
    }

    deinit {
        try? FileManager.default.removeItem(at: paths.root)
    }

    func samples(_ id: UUID, _ ch: AudioChannel) throws -> Int {
        session.waitForPendingWrites()
        let url = paths.trackURL(id, ch)
        return FileManager.default.fileExists(atPath: url.path) ? try PCMTrackReader.sampleCount(url) : 0
    }
}

@Test func startCreatesMeetingAndFiles() throws {
    let f = try Fixture()
    let m = try f.session.start()
    #expect(f.session.state == .recording)
    #expect(try f.repo.meeting(m.id)?.status == .recording)
    #expect(try f.repo.tracks(m.id).count == 2)
    f.mic.emitSamples(1_600)
    f.system.emitSamples(1_600)
    #expect(try f.samples(m.id, .mic) == 1_600)
    #expect(try f.samples(m.id, .system) == 1_600)
}

@Test func pausedChunksAreDropped() throws {
    let f = try Fixture()
    let m = try f.session.start()
    f.mic.emitSamples(1_600)
    try f.session.pause()
    #expect(f.session.state == .paused)
    f.mic.emitSamples(1_600)
    #expect(try f.samples(m.id, .mic) == 1_600)
    try f.session.resume()
    f.mic.emitSamples(1_600)
    #expect(try f.samples(m.id, .mic) == 3_200)
}

@Test func lateChunksArePadded() throws {
    let f = try Fixture()
    let m = try f.session.start()
    f.clock.advance(1)
    f.system.emitSamples(1_600)
    // 1 秒时到达的块，其末尾对应会议时间 1 秒：前面补静音，总数 ≈ 16000
    #expect(abs(try f.samples(m.id, .system) - 16_000) <= 1)
}

@Test func markUsesMeetingTime() throws {
    let f = try Fixture()
    let m = try f.session.start()
    f.clock.advance(10)
    try f.session.pause()
    f.clock.advance(5)
    try f.session.resume()
    f.clock.advance(2)
    let mark = try f.session.addMark()
    #expect(mark.at == 12)
    #expect(try f.repo.marks(m.id) == [mark])
}

@Test func stopIsIdempotentAndClosesPause() throws {
    let f = try Fixture()
    let m = try f.session.start()
    f.clock.advance(3)
    try f.session.pause()
    try f.session.stop()
    try f.session.stop()
    let got = try #require(try f.repo.meeting(m.id))
    #expect(got.status == .pendingProcessing)
    #expect(got.endedAt != nil)
    #expect(try f.repo.pauses(m.id).allSatisfy { $0.end != nil })
    #expect(f.mic.stopCount == 1)
    #expect(f.system.stopCount == 1)
    #expect(f.session.state == .stopped)
}

@Test func stopPadsBothTracksToSameLength() throws {
    let f = try Fixture()
    let m = try f.session.start()
    f.clock.advance(2)
    f.mic.emitSamples(32_000)
    try f.session.stop()
    #expect(abs(try f.samples(m.id, .system) - 32_000) <= 1)
}

@Test func startFailureMarksMeetingFailed() throws {
    let f = try Fixture()
    f.system.startError = CaptureError.permissionDenied(.system)
    #expect(throws: CaptureError.permissionDenied(.system)) { try f.session.start() }
    let id = try #require(f.session.meeting?.id)
    #expect(try f.repo.meeting(id)?.status == .failed)
    #expect(f.mic.stopCount == 1)
}

@Test func sourceFailureKeepsOtherTrack() throws {
    let f = try Fixture()
    let m = try f.session.start()
    f.clock.advance(1)
    f.mic.emitSamples(16_000)
    f.system.emitSamples(16_000)
    f.mic.emit(.interrupted("拔掉了"))
    f.clock.advance(2)
    f.system.emitSamples(32_000)
    f.mic.emit(.resumed)
    f.clock.advance(0.1)
    f.mic.emitSamples(1_600)
    #expect(f.session.state == .recording)
    #expect(try f.samples(m.id, .system) == 48_000)
    #expect(abs(try f.samples(m.id, .mic) - 49_600) <= 3_200)
}

@Test func slowTeardownDoesNotExtendMeeting() throws {
    let f = try Fixture()
    let m = try f.session.start()
    f.clock.advance(2)
    f.mic.emitSamples(32_000)
    f.system.emitSamples(32_000)
    let stopAt = f.clock.now
    // 停设备、销毁聚合设备耗时 5 秒
    // 只捕获 clock：捕获 f 会和 f.mic 互相持有，夹具不释放，临时目录删不掉
    f.mic.onStop = { [clock = f.clock] in clock.advance(5) }
    try f.session.stop()
    #expect(try f.repo.meeting(m.id)?.endedAt == stopAt)
    #expect(abs(try f.samples(m.id, .mic) - 32_000) <= 1)
    #expect(abs(try f.samples(m.id, .system) - 32_000) <= 1)
}

@Test func backlogBurstDoesNotShiftTrack() throws {
    let f = try Fixture()
    let m = try f.session.start()
    // 消费端卡顿 0.5 秒后一次性吐出积压：第一块其实在 1.0s 就已采到
    f.clock.advance(1.5)
    f.system.emit(.chunk(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), level: 0.1, pendingLatency: 0.5)))
    f.system.emit(.chunk(AudioChunk(samples: [Float](repeating: 0.1, count: 8_000), level: 0.1, pendingLatency: 0)))
    #expect(abs(try f.samples(m.id, .system) - 24_000) <= 1)
}

@Test func clockDriftIsTrimmed() throws {
    let f = try Fixture()
    let m = try f.session.start()
    // 设备时钟偏快：10 秒里送来 10.5 秒的数据
    for _ in 0..<100 {
        f.clock.advance(0.1)
        f.mic.emitSamples(1_680)
    }
    #expect(abs(try f.samples(m.id, .mic) - 160_000) <= 3_200)
}

/// 记录 onTrackAudio 回调
private final class ForwardLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(AudioChannel, Int, Int)] = []   // (声道, 采样数, 起始位置)
    func add(_ ch: AudioChannel, _ n: Int, _ start: Int) { lock.withLock { items.append((ch, n, start)) } }
    var all: [(AudioChannel, Int, Int)] { lock.withLock { items } }
}

@Test func forwardedStartMatchesTrackPosition() throws {
    let f = try Fixture()
    let log = ForwardLog()
    f.session.onTrackAudio = { ch, samples, start in log.add(ch, samples.count, start) }
    _ = try f.session.start()
    f.clock.advance(1)
    f.system.emitSamples(1_600)
    f.session.waitForPendingWrites()
    #expect(log.all.count == 1)
    #expect(log.all.first?.0 == .system)
    #expect(log.all.first?.1 == 1_600)
    #expect(log.all.first?.2 == 14_400)
}

@Test func pausedAudioIsNotForwarded() throws {
    let f = try Fixture()
    let log = ForwardLog()
    f.session.onTrackAudio = { ch, samples, start in log.add(ch, samples.count, start) }
    _ = try f.session.start()
    f.mic.emitSamples(1_600)
    try f.session.pause()
    f.mic.emitSamples(1_600)
    f.session.waitForPendingWrites()
    #expect(log.all.count == 1)
    try f.session.resume()
    f.mic.emitSamples(1_600)
    f.session.waitForPendingWrites()
    #expect(log.all.count == 2)
    #expect(log.all.last?.2 == 1_600)
}

@Test func droppedLeadIsNotForwarded() throws {
    let f = try Fixture()
    let log = ForwardLog()
    f.session.onTrackAudio = { ch, samples, start in log.add(ch, samples.count, start) }
    _ = try f.session.start()
    f.clock.advance(1)
    f.mic.emitSamples(16_000)
    f.mic.emitSamples(8_000)   // 超前 0.5s，全部丢弃
    f.session.waitForPendingWrites()
    #expect(log.all.map(\.1) == [16_000])
}

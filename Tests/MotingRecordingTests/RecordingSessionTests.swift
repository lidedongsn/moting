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
    f.mic.onStop = { f.clock.advance(5) }
    try f.session.stop()
    #expect(try f.repo.meeting(m.id)?.endedAt == stopAt)
    #expect(abs(try f.samples(m.id, .mic) - 32_000) <= 1)
    #expect(abs(try f.samples(m.id, .system) - 32_000) <= 1)
}

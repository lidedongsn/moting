import Foundation
import Testing
import MotingASR
import MotingCapture
import MotingCore
import MotingStorage
@testable import MotingPipeline

/// 每 1 秒一个窗口，窗口内有非零采样就当作一段人声
final class FakeSegmenter: SpeechSegmenting {
    private(set) var maxRead = 0
    func segment(reader: (Int, Int) throws -> [Float], total: Int, onSpan: (SpeechSpan) throws -> Void) throws {
        var off = 0
        while off < total {
            let n = min(16_000, total - off)
            maxRead = max(maxRead, n)
            let s = try reader(off, n)
            if s.contains(where: { $0 != 0 }) { try onSpan(SpeechSpan(start: off, samples: s)) }
            off += n
        }
    }
}

final class CountingRecognizer: OfflineRecognizing {
    private var n = 0
    func recognize(_ samples: [Float]) throws -> String {
        n += 1
        return "第\(n)段"
    }
}

struct AddPeriod: Punctuating {
    func punctuate(_ text: String) -> String { text + "。" }
}

private final class Env {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("moting-transcribe-\(UUID().uuidString)")
    let paths: AppPaths
    let transcripts: TranscriptRepository
    let meeting = Meeting(id: UUID(), title: "t", startedAt: Date(), endedAt: nil, status: .processing)

    init() throws {
        paths = AppPaths(root: root)
        let db = try AppDatabase.inMemory()
        try MeetingRepository(db: db).insert(meeting, tracks: [])
        transcripts = TranscriptRepository(db: db)
        try paths.ensureMeetingDirectory(meeting.id)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// 写一路：pattern 中每个 Bool 表示 1 秒是否有声音
    func writeTrack(_ ch: AudioChannel, _ pattern: [Bool]) throws {
        let w = try PCMTrackWriter(url: paths.trackURL(meeting.id, ch))
        for on in pattern { try w.append([Float](repeating: on ? 0.2 : 0, count: 16_000)) }
        try w.close()
    }

    func step(_ seg: FakeSegmenter = FakeSegmenter()) -> TranscribeStep {
        TranscribeStep(paths: paths, transcripts: transcripts,
                       makeRecognizer: { CountingRecognizer() }, makeSegmenter: { seg }, makePunctuator: { AddPeriod() })
    }
}

@Test func writesFinalVersionWithMeetingTimes() throws {
    let e = try Env()
    try e.writeTrack(.mic, [false, true, false])
    try e.writeTrack(.system, [true, false, false])
    let v = try e.step().run(meetingID: e.meeting.id, modelID: "m", previousVersion: nil) { _ in }
    let segs = try e.transcripts.segments(versionID: v)
    #expect(segs.count == 2)
    let sys = try #require(segs.first { $0.channel == .system })
    let mic = try #require(segs.first { $0.channel == .mic })
    #expect(sys.start == 0 && sys.end == 1)
    #expect(mic.start == 1 && mic.end == 2)
    #expect(mic.text.hasSuffix("。"))
}

@Test func silentTrackYieldsNoSegments() throws {
    let e = try Env()
    try e.writeTrack(.mic, [false, false])
    try e.writeTrack(.system, [true, false])
    let v = try e.step().run(meetingID: e.meeting.id, modelID: "m", previousVersion: nil) { _ in }
    #expect(try e.transcripts.segments(versionID: v).allSatisfy { $0.channel == .system })
}

@Test func missingTrackIsSkipped() throws {
    let e = try Env()
    try e.writeTrack(.system, [true])
    let v = try e.step().run(meetingID: e.meeting.id, modelID: "m", previousVersion: nil) { _ in }
    #expect(try e.transcripts.segments(versionID: v).count == 1)
}

@Test func rerunReplacesUnfinishedVersion() throws {
    let e = try Env()
    try e.writeTrack(.mic, [true])
    let first = try e.step().run(meetingID: e.meeting.id, modelID: "m", previousVersion: nil) { _ in }
    let second = try e.step().run(meetingID: e.meeting.id, modelID: "m", previousVersion: first) { _ in }
    #expect(first != second)
    #expect(try e.transcripts.segments(versionID: first).isEmpty)
    #expect(try e.transcripts.segments(versionID: second).count == 1)
}

@Test func progressReachesOneAcrossBothTracks() throws {
    let e = try Env()
    try e.writeTrack(.mic, [true, true])
    try e.writeTrack(.system, [true, true])
    var values: [Double] = []
    _ = try e.step().run(meetingID: e.meeting.id, modelID: "m", previousVersion: nil) { values.append($0) }
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(abs((values.last ?? 0) - 1) < 1e-9)
}

@Test func voiceSegmenterReadsInBoundedChunks() {
    // 长会议不整段载入：真实分段器每次最多读 30 秒
    #expect(VoiceSegmenter.readChunk <= 16_000 * 30)
}

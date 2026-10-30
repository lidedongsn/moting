import Foundation
import Testing
import MotingASR
import MotingCapture
import MotingCore
import MotingStorage
@testable import MotingPipeline

/// 假声纹：片段第一个采样值 v 编码为二维向量 [v, √(1-v²)]，与登记的 [1, 0] 的余弦相似度就是 v
struct AmplitudeMatcher: VoiceprintMatching {
    func embedding(_ samples: [Float]) throws -> [Float] {
        guard let v = samples.first else { return [] }
        return [v, (1 - v * v).squareRoot()]
    }
}

private final class FEnv {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("moting-filter-\(UUID().uuidString)")
    let transcripts: TranscriptRepository
    let version: UUID
    let micTrack: URL
    let voiceprint: URL

    /// 每个元素一秒：(相似度, 是否为麦克风片段)
    init(_ seconds: [(Float, AudioChannel)]) throws {
        let db = try AppDatabase.inMemory()
        let m = Meeting(id: UUID(), title: "t", startedAt: Date(), endedAt: nil, status: .processing)
        try MeetingRepository(db: db).insert(m, tracks: [])
        transcripts = TranscriptRepository(db: db)
        version = try transcripts.createVersion(meetingID: m.id, kind: .final, engine: "e", model: "m", createdAt: Date())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        micTrack = root.appendingPathComponent("mic.pcm")
        voiceprint = root.appendingPathComponent("me.f32")
        try VoiceprintMatcher.save([1, 0], to: voiceprint)
        let w = try PCMTrackWriter(url: micTrack)
        for (i, (sim, ch)) in seconds.enumerated() {
            try w.append([Float](repeating: sim, count: 16_000))
            try transcripts.append(TranscriptSegment(versionID: version, channel: ch, start: Double(i), end: Double(i + 1),
                                                     text: "\(ch.rawValue)-\(i)"))
        }
        try w.close()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var texts: [String] { (try? transcripts.segments(versionID: version).map(\.text)) ?? [] }

    func run(voiceprint: URL?) throws -> FilterOutcome {
        try FilterVoiceStep(transcripts: transcripts).run(versionID: version, micTrack: micTrack, voiceprint: voiceprint,
                                                          matcher: { AmplitudeMatcher() }) { _ in }
    }
}

@Test func dropsLowSimilarityMicSegments() throws {
    let e = try FEnv([(0.9, .mic), (0.2, .mic), (0.95, .mic), (0.8, .mic)])
    #expect(try e.run(voiceprint: e.voiceprint) == .filtered)
    #expect(e.texts == ["mic-0", "mic-2", "mic-3"])
}

@Test func skipsWithoutVoiceprint() throws {
    let e = try FEnv([(0.1, .mic), (0.1, .mic)])
    #expect(try e.run(voiceprint: nil) == .skippedNoVoiceprint)
    #expect(e.texts.count == 2)
}

@Test func fallsBackWhenFilterRemovesMost() throws {
    // 4 段里只有 1 段像本人（25% < 30%）：声纹多半不可靠，全部保留
    let e = try FEnv([(0.9, .mic), (0.2, .mic), (0.1, .mic), (0.3, .mic)])
    #expect(try e.run(voiceprint: e.voiceprint) == .fellBack)
    #expect(e.texts.count == 4)
}

@Test func systemSegmentsAreNeverFiltered() throws {
    let e = try FEnv([(0.9, .mic), (0.9, .mic), (0.1, .system)])
    #expect(try e.run(voiceprint: e.voiceprint) == .filtered)
    #expect(e.texts.contains("system-2"))
}

@Test func mergeMarksVersionCompleted() throws {
    let e = try FEnv([(0.9, .mic)])
    let meetingID = try #require(try e.transcripts.segments(versionID: e.version).first?.versionID)
    #expect(meetingID == e.version)
    try MergeStep(transcripts: e.transcripts).run(versionID: e.version)
    // 完成后才能作为正式稿被查到（latestVersion 只认已完成）
    #expect(try e.transcripts.isCompleted(e.version))
}

@Test func hotwordsFileIsParsedPerLine() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("moting-hw-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try " Moting \n\n接口文档\n  \n张三".write(to: url, atomically: true, encoding: .utf8)
    #expect(DefaultStepRunner.loadHotwords(url) == ["Moting", "接口文档", "张三"])
    #expect(DefaultStepRunner.loadHotwords(url.appendingPathExtension("none")).isEmpty)
}

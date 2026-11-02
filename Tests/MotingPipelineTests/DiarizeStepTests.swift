import Foundation
import Testing
import MotingASR
import MotingCapture
import MotingCore
import MotingStorage
@testable import MotingPipeline

struct FakeDiarizer: Diarizing {
    var turns: [SpeakerTurn]
    func diarize(_ samples: [Float]) throws -> [SpeakerTurn] { turns }
}

private final class DEnv {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("moting-diarize-\(UUID().uuidString)")
    let transcripts: TranscriptRepository
    let speakers: SpeakerRepository
    let meetingID: UUID
    let version: UUID
    let track: URL

    init(segments: [(AudioChannel, Double, Double)]) throws {
        let db = try AppDatabase.inMemory()
        let m = Meeting(id: UUID(), title: "t", startedAt: Date(), endedAt: nil, status: .processing)
        try MeetingRepository(db: db).insert(m, tracks: [])
        transcripts = TranscriptRepository(db: db)
        speakers = SpeakerRepository(db: db)
        meetingID = m.id
        version = try transcripts.createVersion(meetingID: m.id, kind: .final, engine: "e", model: "m", createdAt: Date())
        for (ch, s, e) in segments {
            try transcripts.append(TranscriptSegment(versionID: version, channel: ch, start: s, end: e, text: "\(s)"))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        track = root.appendingPathComponent("system.pcm")
        let w = try PCMTrackWriter(url: track)
        try w.append([Float](repeating: 0.1, count: 16_000))
        try w.close()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func labels() throws -> [String: String?] {
        Dictionary(uniqueKeysWithValues: try transcripts.segments(versionID: version).map { ($0.text, $0.speakerLabel) })
    }
}

@Test func labelsByLongestOverlapInFirstAppearanceOrder() throws {
    let e = try DEnv(segments: [(.system, 0, 4), (.system, 5, 9), (.system, 10, 12)])
    // 说话人编号 7 先出现，应成为"说话人 1"
    let d = FakeDiarizer(turns: [SpeakerTurn(start: 0, end: 3, speaker: 7), SpeakerTurn(start: 3, end: 9.5, speaker: 2),
                                 SpeakerTurn(start: 9.5, end: 12, speaker: 7)])
    try DiarizeStep(transcripts: e.transcripts, diarizer: { d }).run(versionID: e.version, systemTrack: e.track) { _ in }
    let l = try e.labels()
    #expect(l["0.0"] == "说话人 1")
    #expect(l["5.0"] == "说话人 2")
    #expect(l["10.0"] == "说话人 1")
}

@Test func micSegmentsAreUntouched() throws {
    let e = try DEnv(segments: [(.mic, 0, 4), (.system, 0, 4)])
    let d = FakeDiarizer(turns: [SpeakerTurn(start: 0, end: 4, speaker: 0)])
    try DiarizeStep(transcripts: e.transcripts, diarizer: { d }).run(versionID: e.version, systemTrack: e.track) { _ in }
    let segs = try e.transcripts.segments(versionID: e.version)
    #expect(segs.first { $0.channel == .mic }?.speakerLabel == nil)
    #expect(segs.first { $0.channel == .system }?.speakerLabel == "说话人 1")
}

@Test func diarizationOnSilenceIsEmpty() throws {
    let e = try DEnv(segments: [(.system, 0, 4)])
    try DiarizeStep(transcripts: e.transcripts, diarizer: { FakeDiarizer(turns: []) })
        .run(versionID: e.version, systemTrack: e.track) { _ in }
    #expect(try e.transcripts.segments(versionID: e.version).first?.speakerLabel == nil)
}

@Test func missingSystemTrackIsSkipped() throws {
    let e = try DEnv(segments: [(.mic, 0, 1)])
    let missing = e.root.appendingPathComponent("none.pcm")
    try DiarizeStep(transcripts: e.transcripts, diarizer: { FakeDiarizer(turns: []) })
        .run(versionID: e.version, systemTrack: missing) { _ in }
}

/// 官方四人中文示例音频，识别出 3–5 个说话人。需要已安装分段与声纹模型、网络，仅在 MOTING_ASR_IT=1 时运行
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_ASR_IT"] == "1"))
func realDiarizationOnFourSpeakerSample() async throws {
    let env = ProcessInfo.processInfo.environment
    let config = URLSessionConfiguration.default
    if let proxy = (env["https_proxy"] ?? env["HTTPS_PROXY"]).flatMap(URL.init(string:)), let host = proxy.host {
        config.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": proxy.port ?? 80]
    }
    let url = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/0-four-speakers-zh.wav")!
    let (tmp, _) = try await URLSession(configuration: config).download(from: url)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let data = try Data(contentsOf: tmp)
    let samples: [Float] = data.dropFirst(44).withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
    let store = ModelStore(root: AppPaths.default.modelsRoot)
    let threshold = env["MOTING_DIAR_THRESHOLD"].flatMap(Float.init) ?? SherpaDiarizer.defaultThreshold
    let d = try SherpaDiarizer(segmentation: OfflineCatalog.segmentation, embedding: OfflineCatalog.embedding,
                               directory: { store.directory(for: $0) }, clusterThreshold: threshold)
    let turns = try d.diarize(samples)
    let speakers = Set(turns.map(\.speaker)).count
    print("阈值 \(threshold)：分离出 \(speakers) 个说话人，\(turns.count) 段")
    #expect((3...5).contains(speakers))
}

@Test func rediarizingClearsOldSpeakerNames() throws {
    // 回归：重新转写后"说话人 1"可能是另一个人，旧的改名不能套上去
    let e = try DEnv(segments: [(.system, 0, 4)])
    try e.speakers.setName(meetingID: e.meetingID, label: "说话人 1", name: "张三")
    let d = FakeDiarizer(turns: [SpeakerTurn(start: 0, end: 4, speaker: 3)])
    try DiarizeStep(transcripts: e.transcripts, speakers: e.speakers, diarizer: { d })
        .run(versionID: e.version, systemTrack: e.track) { _ in }
    #expect(try e.speakers.names(meetingID: e.meetingID).isEmpty)
}

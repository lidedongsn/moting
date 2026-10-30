import Foundation
import Testing
import MotingASR
import MotingCapture
import MotingCore
import MotingStorage
@testable import MotingPipeline

private func tts(_ voice: String, _ text: String) throws -> [Float] {
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("moting-e2e-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", voice, "-o", wav.path, "--data-format=LEI16@16000", text]
    try p.run()
    p.waitUntilExit()
    let d = try Data(contentsOf: wav)
    return d.dropFirst(44).withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
}

/// 合成一场假会议，用真实模型完整跑一遍会后处理。需要已安装默认离线模型与辅助模型，仅在 MOTING_ASR_IT=1 时运行
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_ASR_IT"] == "1"), .timeLimit(.minutes(5)))
func offlinePipelineEndToEnd() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("moting-e2e-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(root: root)
    let db = try AppDatabase.inMemory()
    let meetings = MeetingRepository(db: db), jobs = JobRepository(db: db), transcripts = TranscriptRepository(db: db)
    let m = Meeting(id: UUID(), title: "e2e", startedAt: Date(), endedAt: Date(), status: .pendingProcessing)
    try meetings.insert(m, tracks: [])
    try paths.ensureMeetingDirectory(m.id)

    let mine = try tts("Tingting", "测试环境谁来搭建")
    let theirs = try tts("Meijia", "我来吧周五之前能好")
    let gap = [Float](repeating: 0, count: 16_000)
    // 我先说，对方后说；两路等长
    let micAudio = gap + mine + gap + [Float](repeating: 0, count: theirs.count) + gap
    let sysAudio = gap + [Float](repeating: 0, count: mine.count) + gap + theirs + gap
    for (ch, audio) in [(AudioChannel.mic, micAudio), (.system, sysAudio)] {
        let w = try PCMTrackWriter(url: paths.trackURL(m.id, ch))
        try w.append(audio)
        try w.close()
    }

    let store = ModelStore(root: AppPaths.default.modelsRoot)
    let runner = PipelineRunner(jobs: jobs, meetings: meetings,
                                steps: DefaultStepRunner(paths: paths, transcripts: transcripts, store: store),
                                power: SystemPowerSource(), isRecording: { false })
    try runner.enqueue(meetingID: m.id, modelID: OfflineCatalog.default.id)
    try runner.processNow(meetingID: m.id)
    let t0 = Date()
    await runner.drain()
    let job = try #require(try jobs.job(for: m.id))
    #expect(job.status == .done, "\(job.error ?? "")")
    #expect(job.filterOutcome == FilterOutcome.skippedNoVoiceprint.rawValue)
    let v = try #require(try transcripts.latestVersion(meetingID: m.id, kind: .final))
    let segs = try transcripts.segments(versionID: v)
    for s in segs { print(String(format: "[%.1f-%.1f] %@ %@", s.start, s.end, s.speakerLabel ?? s.channel.rawValue, s.text)) }
    print(String(format: "音频 %.1f 秒，会后处理 %.1f 秒", Double(micAudio.count) / 16_000, Date().timeIntervalSince(t0)))
    #expect(segs.first { $0.channel == .mic }?.text.contains("测试环境") == true)
    #expect(segs.first { $0.channel == .system }?.speakerLabel == "说话人 1")
    #expect(try meetings.meeting(m.id)?.status == .done)
}

import Foundation
import Testing
import MotingCore
import MotingStorage
@testable import MotingPipeline

private let v = UUID()

private func seg(_ ch: AudioChannel, _ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(id: UUID(), versionID: v, channel: ch, start: start, end: end, text: text)
}

@Test func micLineRepeatingSpeakerAtSameTimeIsEcho() {
    let sys = seg(.system, 10, 14, "第一件事，接口文档需要在周三之前定稿。")
    let echo = seg(.mic, 10.1, 14.2, "第一件事接口文档需要在装三之前定稿")    // 识别有点出入
    #expect(EchoDedup.echoSegmentIDs([sys, echo]) == [echo.id])
}

@Test func ownSpeechIsKept() {
    let sys = seg(.system, 10, 14, "第一件事，接口文档需要在周三之前定稿。")
    let me = seg(.mic, 14.5, 16, "好的，我这边周二就能给。")
    #expect(EchoDedup.echoSegmentIDs([sys, me]).isEmpty)
}

@Test func sameWordsAtDifferentTimeAreNotEcho() {
    // 自己后来复述了一遍，不是回声
    let sys = seg(.system, 10, 14, "接口文档需要在周三之前定稿")
    let me = seg(.mic, 40, 43, "接口文档需要在周三之前定稿")
    #expect(EchoDedup.echoSegmentIDs([sys, me]).isEmpty)
}

@Test func echoSpanningTwoSpeakerLinesIsFound() {
    // 两路断句不同：麦克风一句对应系统两句
    let a = seg(.system, 10, 12, "测试环境由王蕾负责搭建。")
    let b = seg(.system, 12.2, 14, "周五之前完成。")
    let echo = seg(.mic, 10, 14.1, "测试环境由王磊负责搭建周五之前完成")
    #expect(EchoDedup.echoSegmentIDs([a, b, echo]) == [echo.id])
}

@Test func shortRepliesAreNeverJudged() {
    let sys = seg(.system, 10, 11, "好的好的。")
    let me = seg(.mic, 10.2, 10.8, "好的")
    #expect(EchoDedup.echoSegmentIDs([sys, me]).isEmpty)
}

@Test func mixedLineWithMostlyOwnWordsIsKept() {
    // 外放的同时自己插话，识别成一句：大部分是自己的话就保留
    let sys = seg(.system, 10, 12, "周五之前完成")
    let me = seg(.mic, 10, 13, "周五可能来不及，我们能不能顺延到下周二再交")
    #expect(EchoDedup.echoSegmentIDs([sys, me]).isEmpty)
}

@Test func mergeRemovesSpeakerEchoFromFinalTranscript() throws {
    let db = try AppDatabase.inMemory()
    let m = Meeting(id: UUID(), title: "t", startedAt: Date(), endedAt: nil, status: .processing)
    try MeetingRepository(db: db).insert(m, tracks: [])
    let transcripts = TranscriptRepository(db: db)
    let version = try transcripts.createVersion(meetingID: m.id, kind: .final, engine: "e", model: "m", createdAt: Date())
    let sys = TranscriptSegment(versionID: version, channel: .system, start: 10, end: 14, text: "导出功能放到下一个迭代。")
    let echo = TranscriptSegment(versionID: version, channel: .mic, start: 10, end: 14, text: "导出功能放到下一个迭代")
    let me = TranscriptSegment(versionID: version, channel: .mic, start: 15, end: 16, text: "行，没问题。")
    for s in [sys, echo, me] { try transcripts.append(s) }
    try MergeStep(transcripts: transcripts).run(versionID: version)
    let left: Set<UUID> = Set(try transcripts.segments(versionID: version).map(\.id))
    #expect(left == [sys.id, me.id])
    #expect(try transcripts.isCompleted(version))
}

// MARK: - 按能量判断回声

private func noise(_ n: Int, seed: UInt64) -> [Float] {
    var g = seed
    return (0..<n).map { _ in
        g = g &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: g >> 11) % 2000) / 1000 - 1
    }
}

private func speech(seconds: Double, seed: UInt64, rate: Float) -> [Float] {
    let n = Int(seconds * 16_000)
    let x = noise(n, seed: seed)
    return (0..<n).map { i in x[i] * max(0, sin(Float(i) / 16_000 * 2 * .pi * rate)) * 0.5 }
}

private func writePCM(_ x: [Float], to url: URL) throws {
    var d = Data(capacity: x.count * 2)
    for v in x { withUnsafeBytes(of: Int16(max(-32_768, min(32_767, v * 32_767))).littleEndian) { d.append(contentsOf: $0) } }
    try d.write(to: url)
}

@Test func mergeRemovesEchoJudgedByEnergyEvenWhenTextDiffers() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // 对方一直在说；扬声器漏进麦克风（晚 60ms、×0.3）；20–30 秒自己也在说
    let system = speech(seconds: 60, seed: 3, rate: 2.3)
    var mic = (0..<system.count).map { i in (i >= 960 ? system[i - 960] * 0.3 : 0) }
    let mine = speech(seconds: 10, seed: 21, rate: 3.1)
    for i in mine.indices { mic[20 * 16_000 + i] += mine[i] * 0.8 }
    let micURL = dir.appendingPathComponent("mic.pcm"), sysURL = dir.appendingPathComponent("system.pcm")
    try writePCM(mic, to: micURL)
    try writePCM(system, to: sysURL)

    let db = try AppDatabase.inMemory()
    let m = Meeting(id: UUID(), title: "t", startedAt: Date(), endedAt: nil, status: .processing)
    try MeetingRepository(db: db).insert(m, tracks: [])
    let transcripts = TranscriptRepository(db: db)
    let version = try transcripts.createVersion(meetingID: m.id, kind: .final, engine: "e", model: "m", createdAt: Date())
    // 回声被识别得和对方那句对不上，文字去重抓不到
    let sys = TranscriptSegment(versionID: version, channel: .system, start: 40, end: 44, text: "导出功能放到下一个迭代。")
    let echo = TranscriptSegment(versionID: version, channel: .mic, start: 40, end: 44, text: "倒出公能放刀")
    let me = TranscriptSegment(versionID: version, channel: .mic, start: 21, end: 29, text: "我觉得这个可以再商量。")
    for s in [sys, echo, me] { try transcripts.append(s) }
    try MergeStep(transcripts: transcripts).run(versionID: version, micTrack: micURL, systemTrack: sysURL)
    let left: Set<UUID> = Set(try transcripts.segments(versionID: version).map(\.id))
    #expect(left == [sys.id, me.id])
}

@Test func mergeWithoutTracksStillWorks() throws {
    let db = try AppDatabase.inMemory()
    let m = Meeting(id: UUID(), title: "t", startedAt: Date(), endedAt: nil, status: .processing)
    try MeetingRepository(db: db).insert(m, tracks: [])
    let transcripts = TranscriptRepository(db: db)
    let version = try transcripts.createVersion(meetingID: m.id, kind: .final, engine: "e", model: "m", createdAt: Date())
    let me = TranscriptSegment(versionID: version, channel: .mic, start: 1, end: 3, text: "你好。")
    try transcripts.append(me)
    let missing = URL(fileURLWithPath: "/nonexistent/mic.pcm")
    try MergeStep(transcripts: transcripts).run(versionID: version, micTrack: missing, systemTrack: missing)
    #expect(try transcripts.segments(versionID: version).map(\.id) == [me.id])
}

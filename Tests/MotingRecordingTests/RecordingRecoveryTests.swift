import Foundation
import Testing
import MotingCore
import MotingStorage
@testable import MotingRecording

private func setup(status: MeetingStatus) throws -> (MeetingRepository, AppPaths, Meeting) {
    let repo = MeetingRepository(db: try AppDatabase.inMemory())
    let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let m = Meeting(id: UUID(), title: "t", startedAt: Date(timeIntervalSince1970: 1_000), endedAt: nil, status: status)
    try repo.insert(m, tracks: [])
    try paths.ensureMeetingDirectory(m.id)
    return (repo, paths, m)
}

private func size(_ url: URL) throws -> Int {
    try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
}

@Test func recoversInterruptedMeeting() throws {
    let (repo, paths, m) = try setup(status: .recording)
    FileManager.default.createFile(atPath: paths.trackURL(m.id, .mic).path, contents: Data(count: 16_001))
    FileManager.default.createFile(atPath: paths.trackURL(m.id, .system).path, contents: Data(count: 32_000))
    try repo.beginPause(meetingID: m.id, at: Date(timeIntervalSince1970: 1_000.5))
    let now = Date(timeIntervalSince1970: 1_010)

    let ids = try RecordingRecovery.run(repository: repo, paths: paths, now: now)

    #expect(ids == [m.id])
    let got = try #require(try repo.meeting(m.id))
    #expect(got.status == .interrupted)
    #expect(try size(paths.trackURL(m.id, .mic)) == 16_000)
    #expect(try repo.pauses(m.id).allSatisfy { $0.end != nil })
    // 崩溃时间未知：未结束的暂停按零时长关闭（结束于其开始时刻），
    // endedAt = 开始 + 最长一路 1 秒 + 已结束暂停 0 秒
    let end = try #require(got.endedAt)
    #expect(abs(end.timeIntervalSince1970 - 1_001) < 0.01)
    #expect(try repo.pauses(m.id).first?.end == Date(timeIntervalSince1970: 1_000.5))
}

@Test func leavesFinishedMeetingsAlone() throws {
    let (repo, paths, m) = try setup(status: .pendingProcessing)
    #expect(try RecordingRecovery.run(repository: repo, paths: paths, now: Date()).isEmpty)
    #expect(try repo.meeting(m.id)?.status == .pendingProcessing)
}

@Test func missingTrackFileIsTolerated() throws {
    let (repo, paths, m) = try setup(status: .recording)
    FileManager.default.createFile(atPath: paths.trackURL(m.id, .mic).path, contents: Data(count: 32_000))
    #expect(try RecordingRecovery.run(repository: repo, paths: paths, now: Date()) == [m.id])
    #expect(try repo.meeting(m.id)?.status == .interrupted)
}

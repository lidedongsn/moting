import Foundation
import Testing
import MotingCore
@testable import MotingStorage

private func makeRepo() throws -> MeetingRepository {
    MeetingRepository(db: try AppDatabase.inMemory())
}

private func meeting(_ t: TimeInterval, status: MeetingStatus = .recording) -> Meeting {
    Meeting(id: UUID(), title: "m\(t)", startedAt: Date(timeIntervalSince1970: t), endedAt: nil, status: status)
}

@Test func insertAndListNewestFirst() async throws {
    let repo = try makeRepo()
    let old = meeting(100), new = meeting(200)
    try repo.insert(old, tracks: [])
    try repo.insert(new, tracks: [])
    for try await list in repo.observeAll() {
        #expect(list == [new, old])
        break
    }
}

@Test func statusUpdateSetsEndedAt() throws {
    let repo = try makeRepo()
    let m = meeting(100)
    try repo.insert(m, tracks: [])
    let end = Date(timeIntervalSince1970: 160)
    try repo.setStatus(m.id, .pendingProcessing, endedAt: end)
    let got = try #require(try repo.meeting(m.id))
    #expect(got.status == .pendingProcessing)
    #expect(got.endedAt == end)
}

@Test func pauseOpenAndClose() throws {
    let repo = try makeRepo()
    let m = meeting(100)
    try repo.insert(m, tracks: [])
    try repo.beginPause(meetingID: m.id, at: Date(timeIntervalSince1970: 110))
    try repo.endOpenPause(meetingID: m.id, at: Date(timeIntervalSince1970: 115))
    try repo.endOpenPause(meetingID: m.id, at: Date(timeIntervalSince1970: 120))
    let pauses = try repo.pauses(m.id)
    #expect(pauses.count == 1)
    #expect(pauses[0].start == Date(timeIntervalSince1970: 110))
    #expect(pauses[0].end == Date(timeIntervalSince1970: 115))
}

@Test func marksAndTracksRoundTrip() throws {
    let repo = try makeRepo()
    let m = meeting(100)
    let tracks = AudioChannel.allCases.map {
        AudioTrackInfo(meetingID: m.id, channel: $0, relativePath: "meetings/\(m.id)/\($0.rawValue).pcm", sampleRate: 16_000)
    }
    try repo.insert(m, tracks: tracks)
    let mark = Mark(meetingID: m.id, at: 12.5)
    try repo.addMark(mark)
    #expect(try repo.marks(m.id) == [mark])
    #expect(Set(try repo.tracks(m.id).map(\.channel)) == [.mic, .system])
    #expect(try repo.tracks(m.id).allSatisfy { $0.sampleRate == 16_000 })
}

@Test func meetingsByStatus() throws {
    let repo = try makeRepo()
    let a = meeting(100), b = meeting(200, status: .done)
    try repo.insert(a, tracks: [])
    try repo.insert(b, tracks: [])
    #expect(try repo.meetings(status: .recording).map(\.id) == [a.id])
}

@Test func pathsLayout() {
    let p = AppPaths(root: URL(fileURLWithPath: "/tmp/x"))
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    #expect(p.trackURL(id, .mic).path == "/tmp/x/meetings/00000000-0000-0000-0000-000000000001/mic.pcm")
    #expect(p.databaseURL.path == "/tmp/x/moting.sqlite")
}

@Test func openOnDiskCreatesFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let paths = AppPaths(root: dir)
    _ = try AppDatabase.open(at: paths.databaseURL)
    #expect(FileManager.default.fileExists(atPath: paths.databaseURL.path))
    try? FileManager.default.removeItem(at: dir)
}

@Test func deleteRemovesMeetingAndChildren() throws {
    let repo = try makeRepo()
    let m = meeting(100)
    try repo.insert(m, tracks: [AudioTrackInfo(meetingID: m.id, channel: .mic, relativePath: "x", sampleRate: 16_000)])
    try repo.addMark(Mark(meetingID: m.id, at: 1))
    try repo.beginPause(meetingID: m.id, at: Date())
    try repo.delete(m.id)
    #expect(try repo.meeting(m.id) == nil)
    #expect(try repo.tracks(m.id).isEmpty)
    #expect(try repo.marks(m.id).isEmpty)
    #expect(try repo.pauses(m.id).isEmpty)
}

@Test func storageUsageCountsMeetingFiles() throws {
    let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let id = UUID()
    try paths.ensureMeetingDirectory(id)
    FileManager.default.createFile(atPath: paths.trackURL(id, .mic).path, contents: Data(count: 1_000))
    FileManager.default.createFile(atPath: paths.trackURL(id, .system).path, contents: Data(count: 3_000))
    #expect(paths.meetingsDiskUsage() == 4_000)
    #expect(paths.diskUsage(of: id) == 4_000)
}

@Test func modelsUsageIsSeparateFromMeetings() throws {
    let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let dir = paths.modelsRoot.appendingPathComponent("m1")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir.appendingPathComponent("a.onnx").path, contents: Data(count: 2_000))
    #expect(paths.modelsRoot.path.hasSuffix("/models"))
    #expect(paths.modelsDiskUsage() == 2_000)
    #expect(paths.meetingsDiskUsage() == 0)
}

@Test func renameUpdatesTitle() throws {
    let repo = try makeRepo()
    let m = meeting(100)
    try repo.insert(m, tracks: [])
    try repo.rename(m.id, to: "  周会：接口评审  ")
    #expect(try repo.meeting(m.id)?.title == "周会：接口评审")
}

@Test func renameIgnoresBlankTitle() throws {
    let repo = try makeRepo()
    let m = meeting(100)
    try repo.insert(m, tracks: [])
    try repo.rename(m.id, to: "   ")
    #expect(try repo.meeting(m.id)?.title == m.title)
}

@Test func updateStatusKeepsEndedAt() throws {
    let repo = try makeRepo()
    let m = meeting(100)
    try repo.insert(m, tracks: [])
    let end = Date(timeIntervalSince1970: 160)
    try repo.setStatus(m.id, .pendingProcessing, endedAt: end)
    try repo.updateStatus(m.id, .processing)
    #expect(try repo.meeting(m.id)?.status == .processing)
    #expect(try repo.meeting(m.id)?.endedAt == end)
}

@Test func uninstallCoversEverythingOutsideTheDataFolder() {
    let home = URL(fileURLWithPath: "/Users/x")
    let paths = AppPaths.systemLeftovers(home: home, bundleID: "com.example.app").map(\.path)
    #expect(paths.contains("/Users/x/Library/Caches/com.example.app"))
    #expect(paths.contains("/Users/x/Library/HTTPStorages/com.example.app"))
    #expect(paths.contains("/Users/x/Library/Saved Application State/com.example.app.savedState"))
}

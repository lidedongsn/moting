import Foundation
import GRDB
import Testing
import MotingCore
@testable import MotingStorage

private func tempDB() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("moting-privacy-\(UUID().uuidString)/moting.sqlite")
}

private func fileContains(_ url: URL, _ marker: String) throws -> Bool {
    try Data(contentsOf: url).range(of: Data(marker.utf8)) != nil
}

/// 把所有文件内容查一遍：主文件和 WAL
private func anywhere(_ url: URL, _ marker: String) throws -> Bool {
    for suffix in ["", "-wal"] {
        let f = URL(fileURLWithPath: url.path + suffix)
        if FileManager.default.fileExists(atPath: f.path), try fileContains(f, marker) { return true }
    }
    return false
}

private func addMeeting(_ db: AppDatabase, text: String) throws -> UUID {
    let meetings = MeetingRepository(db: db)
    let m = Meeting(id: UUID(), title: "t", startedAt: Date(), endedAt: nil, status: .done)
    try meetings.insert(m, tracks: [])
    let repo = TranscriptRepository(db: db)
    let v = try repo.createVersion(meetingID: m.id, kind: .final, engine: "e", model: "m", createdAt: Date())
    try repo.append(TranscriptSegment(versionID: v, channel: .mic, start: 0, end: 1, text: text))
    return m.id
}

@Test func deletedMeetingTextDoesNotStayInTheDatabaseFile() throws {
    let url = tempDB()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let marker = "只有这场会议才说过的机密内容ABC123"
    let db = try AppDatabase.open(at: url)
    let id = try addMeeting(db, text: marker)
    try db.writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    #expect(try fileContains(url, marker), "先确认测试方法有效：写进去时能查到")
    try MeetingRepository(db: db).delete(id)
    try db.writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    #expect(try !anywhere(url, marker))
}

@Test func leftoverFreePagesFromOlderVersionsAreClearedOnOpen() throws {
    // 老版本没开 secure_delete：删过的内容还留在空闲页里，升级后打开时要清掉
    let url = tempDB()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let marker = "老版本删掉但还留在文件里的内容XYZ789"
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        let old = try DatabaseQueue(path: url.path)
        try old.write { db in
            try db.execute(sql: "PRAGMA secure_delete = OFF")
            try db.execute(sql: "CREATE TABLE junk (t TEXT)")
            for _ in 0..<200 { try db.execute(sql: "INSERT INTO junk VALUES (?)", arguments: [String(repeating: marker, count: 20)]) }
        }
        try old.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA secure_delete = OFF")
            try db.execute(sql: "DELETE FROM junk")
        }
        try old.close()
    }
    #expect(try fileContains(url, marker), "确认内容确实留在空闲页里")
    let db = try AppDatabase.open(at: url)
    try db.writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    #expect(try !anywhere(url, marker))
}

@Test func openingKeepsExistingData() throws {
    let url = tempDB()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let id: UUID
    do { id = try addMeeting(try AppDatabase.open(at: url), text: "保留") }
    let reopened = try AppDatabase.open(at: url)
    #expect(try MeetingRepository(db: reopened).meeting(id) != nil)
}

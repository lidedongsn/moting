import Foundation
import Testing
import MotingCore
@testable import MotingStorage

private func setup() throws -> (SummaryRepository, MeetingRepository, UUID) {
    let db = try AppDatabase.inMemory()
    let meetings = MeetingRepository(db: db)
    let m = Meeting(id: UUID(), title: "t", startedAt: Date(), endedAt: nil, status: .done)
    try meetings.insert(m, tracks: [])
    return (SummaryRepository(db: db), meetings, m.id)
}

@Test func savesAndLoadsSummary() throws {
    let (repo, _, id) = try setup()
    #expect(try repo.load(meetingID: id) == nil)
    let s = MeetingSummary(overview: "概要", decisions: ["定了"], todos: [.init(task: "写文档", owner: "我")])
    let at = Date(timeIntervalSince1970: 1_000)
    try repo.save(meetingID: id, summary: s, provider: "DeepSeek", model: "deepseek-flash", at: at)
    let got = try #require(try repo.load(meetingID: id))
    #expect(got.summary == s)
    #expect(got.provider == "DeepSeek")
    #expect(got.model == "deepseek-flash")
    #expect(got.createdAt == at)
    #expect(got.error == nil)
}

@Test func regeneratingReplacesPrevious() throws {
    let (repo, _, id) = try setup()
    try repo.save(meetingID: id, summary: MeetingSummary(overview: "旧"), provider: "p", model: "m", at: Date())
    try repo.save(meetingID: id, summary: MeetingSummary(overview: "新"), provider: "p", model: "m", at: Date())
    #expect(try repo.load(meetingID: id)?.summary?.overview == "新")
}

@Test func failureKeepsRawReply() throws {
    let (repo, _, id) = try setup()
    try repo.saveFailure(meetingID: id, raw: "不是 JSON", error: "解析失败", provider: "p", model: "m", at: Date())
    let got = try #require(try repo.load(meetingID: id))
    #expect(got.summary == nil)
    #expect(got.raw == "不是 JSON")
    #expect(got.error == "解析失败")
}

@Test func todoCanBeCheckedOff() throws {
    let (repo, _, id) = try setup()
    let todo = MeetingSummary.Todo(task: "写文档")
    try repo.save(meetingID: id, summary: MeetingSummary(overview: "x", todos: [todo]), provider: "p", model: "m", at: Date())
    try repo.setTodo(meetingID: id, todoID: todo.id, done: true)
    #expect(try repo.load(meetingID: id)?.summary?.todos.first?.done == true)
}

@Test func deletingMeetingDeletesSummary() throws {
    let (repo, meetings, id) = try setup()
    try repo.save(meetingID: id, summary: MeetingSummary(overview: "x"), provider: "p", model: "m", at: Date())
    try meetings.delete(id)
    #expect(try repo.load(meetingID: id) == nil)
}

@Test func failedRegenerationKeepsPreviousSummary() throws {
    // 回归：重新生成失败曾把好的纪要（含已勾选的待办）整个覆盖掉
    let (repo, _, id) = try setup()
    let todo = MeetingSummary.Todo(task: "写文档", done: true)
    try repo.save(meetingID: id, summary: MeetingSummary(overview: "好的", todos: [todo]), provider: "p", model: "m", at: Date())
    try repo.saveFailure(meetingID: id, raw: "乱码", error: "解析失败", provider: "p", model: "m", at: Date())
    let got = try #require(try repo.load(meetingID: id))
    #expect(got.summary?.overview == "好的")
    #expect(got.summary?.todos.first?.done == true)
    #expect(got.error == "解析失败")
    #expect(got.raw == "乱码")
    // 之后成功生成会清掉错误
    try repo.save(meetingID: id, summary: MeetingSummary(overview: "新的"), provider: "p", model: "m", at: Date())
    #expect(try repo.load(meetingID: id)?.error == nil)
}

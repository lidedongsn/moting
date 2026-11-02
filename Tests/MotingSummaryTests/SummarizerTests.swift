import Foundation
import Testing
import MotingCore
@testable import MotingSummary

/// 按脚本回复的假模型，记下每次收到的提示词
final class FakeChat: ChatCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private(set) var prompts: [(system: String, user: String)] = []

    init(_ replies: [String]) { self.replies = replies }

    func complete(system: String, user: String) async throws -> String {
        lock.withLock {
            prompts.append((system, user))
            return replies.isEmpty ? "" : replies.removeFirst()
        }
    }
}

let validReply = """
{"overview":"订单接口周三前定稿。","topics":[{"title":"订单接口","points":["文档周三前定稿"]}],
 "decisions":["导出功能延后"],"todos":[{"task":"定稿接口文档","owner":"李思远","due":"周三"},{"task":"整理待办","owner":"","due":null}]}
"""

private let meeting = Meeting(id: UUID(), title: "周会", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, status: .done)

private func seg(_ ch: AudioChannel, _ s: TimeInterval, _ text: String, speaker: String? = nil) -> TranscriptSegment {
    TranscriptSegment(versionID: UUID(), channel: ch, speakerLabel: speaker, start: s, end: s + 2, text: text)
}

private let segments = [seg(.mic, 5, "测试环境谁来搭？"), seg(.system, 9, "我来吧，周五之前。", speaker: "说话人 1")]

@Test func parsesModelJSONIntoSummary() throws {
    let s = try SummaryParser.parse(validReply)
    #expect(s.overview == "订单接口周三前定稿。")
    #expect(s.topics == [.init(title: "订单接口", points: ["文档周三前定稿"])])
    #expect(s.decisions == ["导出功能延后"])
    #expect(s.todos.map(\.task) == ["定稿接口文档", "整理待办"])
    #expect(s.todos[0].owner == "李思远" && s.todos[0].due == "周三")
    #expect(s.todos[1].owner == nil && s.todos[1].due == nil, "空负责人当作没有")
}

@Test func parserToleratesCodeFenceAndRejectsBlank() throws {
    #expect(try SummaryParser.parse("```json\n\(validReply)\n```").overview == "订单接口周三前定稿。")
    // DeepSeek JSON 模式解析不出时会返回全是空格的内容
    #expect(throws: SummaryError.self) { try SummaryParser.parse("   \n ") }
}

@Test func promptCarriesTranscriptAndMarks() async throws {
    let chat = FakeChat([validReply])
    _ = try await Summarizer(chat: chat, contextChars: 100_000)
        .summarize(meeting: meeting, segments: segments, marks: [Mark(meetingID: meeting.id, at: 8)],
                   names: ["说话人 1": "王蕾"])
    let p = try #require(chat.prompts.first)
    #expect(p.user.contains("[00:05] 我：测试环境谁来搭？"))
    #expect(p.user.contains("[00:09] 王蕾：我来吧，周五之前。"), "用改过的名字")
    #expect(p.user.contains("★ 00:08"))
    #expect((p.system + p.user).lowercased().contains("json"), "DeepSeek JSON 模式要求提示词里出现 json")
}

@Test func retriesOnceWhenReplyIsNotJSON() async throws {
    let chat = FakeChat(["这不是 JSON", validReply])
    let s = try await Summarizer(chat: chat, contextChars: 100_000).summarize(meeting: meeting, segments: segments, marks: [], names: [:])
    #expect(s.overview == "订单接口周三前定稿。")
    #expect(chat.prompts.count == 2)
}

@Test func givesUpAfterSecondBadReplyKeepingRaw() async throws {
    let chat = FakeChat(["坏的一", "坏的二"])
    do {
        _ = try await Summarizer(chat: chat, contextChars: 100_000).summarize(meeting: meeting, segments: segments, marks: [], names: [:])
        Issue.record("应当失败")
    } catch SummaryError.unparseable(let raw) {
        #expect(raw == "坏的二")
    }
    #expect(chat.prompts.count == 2)
}

@Test func longMeetingIsSummarizedInPartsThenMerged() async throws {
    let many = (0..<40).map { seg(.mic, Double($0) * 10, String(repeating: "很长的发言内容", count: 5)) }
    let chat = FakeChat(Array(repeating: validReply, count: 10))
    _ = try await Summarizer(chat: chat, contextChars: 800).summarize(meeting: meeting, segments: many, marks: [], names: [:])
    #expect(chat.prompts.count >= 3, "至少两段 + 一次汇总")
    #expect(chat.prompts.last!.user.contains("分段纪要"), "最后一次是汇总")
    // 每段都不超过上限
    for p in chat.prompts.dropLast() { #expect(p.user.count < 800 + 2_000) }
}

@Test func emptyTranscriptIsRejectedWithoutCallingModel() async throws {
    let chat = FakeChat([validReply])
    await #expect(throws: SummaryError.self) {
        _ = try await Summarizer(chat: chat, contextChars: 100_000).summarize(meeting: meeting, segments: [], marks: [], names: [:])
    }
    #expect(chat.prompts.isEmpty)
}

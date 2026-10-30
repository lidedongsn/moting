import Foundation
import Testing
@testable import MotingCore

private let start = ISO8601DateFormatter().date(from: "2026-10-30T06:00:00Z")!

private func seg(_ ch: AudioChannel, _ s: TimeInterval, _ text: String, speaker: String? = nil) -> TranscriptSegment {
    TranscriptSegment(versionID: UUID(), channel: ch, speakerLabel: speaker, start: s, end: s + 2, text: text)
}

@Test func exportsHeaderMarksAndTranscript() {
    let m = Meeting(id: UUID(), title: "周会", startedAt: start, endedAt: start + 3_720, status: .pendingProcessing)
    let md = MarkdownExporter.export(meeting: m, segments: [seg(.system, 200, "接口文档周三前定。"), seg(.mic, 192, "测试环境谁来搭？")],
                                     marks: [Mark(meetingID: m.id, at: 195)], timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    #expect(md.hasPrefix("# 周会\n"))
    #expect(md.contains("- 时间：2026-10-30 14:00–15:02（62 分钟）"))
    #expect(md.contains("## 重点标记\n- [00:03:15]"))
    // 转写稿按时间排序，我 / 对方
    let mine = md.range(of: "**[00:03:12] 我：** 测试环境谁来搭？")
    let theirs = md.range(of: "**[00:03:20] 对方：** 接口文档周三前定。")
    #expect(mine != nil && theirs != nil)
    #expect(mine!.lowerBound < theirs!.lowerBound)
}

@Test func speakerLabelOverridesChannelName() {
    let m = Meeting(id: UUID(), title: "t", startedAt: start, endedAt: start + 60, status: .done)
    let md = MarkdownExporter.export(meeting: m, segments: [seg(.system, 5, "你好", speaker: "张三")], marks: [],
                                     timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    #expect(md.contains("**[00:00:05] 张三：** 你好"))
    #expect(!md.contains("## 重点标记"))
}

@Test func emptyTranscriptSaysSo() {
    let m = Meeting(id: UUID(), title: "t", startedAt: start, endedAt: nil, status: .interrupted)
    let md = MarkdownExporter.export(meeting: m, segments: [], marks: [], timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    #expect(md.contains("## 转写稿\n\n（暂无转写内容）"))
    #expect(md.contains("- 时间：2026-10-30 14:00"))
}

@Test func renamedSpeakersAreUsed() {
    let m = Meeting(id: UUID(), title: "t", startedAt: start, endedAt: start + 60, status: .done)
    let md = MarkdownExporter.export(meeting: m, segments: [seg(.system, 5, "你好", speaker: "说话人 1"), seg(.system, 9, "嗯", speaker: "说话人 2")],
                                     marks: [], names: ["说话人 1": "张三"], timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    #expect(md.contains("**[00:00:05] 张三：** 你好"))
    #expect(md.contains("**[00:00:09] 说话人 2：** 嗯"))
    #expect(md.contains("- 参会：我、张三、说话人 2"))
}

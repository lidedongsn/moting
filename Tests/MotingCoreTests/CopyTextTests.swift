import Foundation
import Testing
@testable import MotingCore

private let version = UUID()
private func seg(_ ch: AudioChannel, _ label: String?, _ start: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(versionID: version, channel: ch, speakerLabel: label, start: start, end: start + 1, text: text)
}

@Test func transcriptIsGroupedByTurnWithNameAndTime() {
    let text = CopyText.transcript(title: "周会", segments: [
        seg(.mic, nil, 1, "第一句。"), seg(.mic, nil, 2, "第二句。"), seg(.system, "说话人 1", 65, "好的。"),
    ], names: [:])
    #expect(text == """
    周会

    我 00:00:01
    第一句。第二句。

    说话人 1 00:01:05
    好的。
    """)
}

@Test func transcriptUsesRealNames() {
    let text = CopyText.transcript(title: "周会", segments: [seg(.system, "说话人 1", 0, "好的。")], names: ["说话人 1": "张三"])
    #expect(text.contains("张三 00:00:00"))
    #expect(!text.contains("说话人 1"))
}

@Test func transcriptHasNoMarkdownSymbols() {
    let text = CopyText.transcript(title: "周会", segments: [seg(.mic, nil, 0, "你好。")], names: [:])
    #expect(!text.contains("**") && !text.contains("#"))
}

@Test func emptyTranscriptIsJustTheTitle() {
    #expect(CopyText.transcript(title: "周会", segments: [], names: [:]) == "周会")
}

@Test func notesKeepAReadableOrder() {
    let s = MeetingSummary(overview: "总结一句。",
                           topics: [.init(title: "议题一", points: ["要点"])],
                           decisions: ["决定一"],
                           todos: [.init(task: "写文档", owner: "张三", due: "周五"), .init(task: "已做的", done: true)])
    #expect(CopyText.notes(title: "周会", summary: s) == """
    周会

    概要
    总结一句。

    决策
    - 决定一

    待办
    - [ ] 写文档（张三 · 周五）
    - [x] 已做的

    议题
    议题一
    - 要点
    """)
}

@Test func emptySectionsAreLeftOut() {
    let text = CopyText.notes(title: "周会", summary: MeetingSummary(overview: "总结。"))
    #expect(text == "周会\n\n概要\n总结。")
}

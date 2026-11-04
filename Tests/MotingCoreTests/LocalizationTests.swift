import Foundation
import Testing
@testable import MotingCore

@Test func recognizesNumberedSpeakerLabels() {
    #expect(SpeakerLabel.number(in: "说话人 12") == 12)
    #expect(SpeakerLabel.number(in: "说话人 张三") == nil)
    #expect(SpeakerLabel.number(in: "张三") == nil)
}

@Test func realNamesAreNeverTranslated() {
    #expect(SpeakerLabel.display("张三") == "张三")
    #expect(SpeakerLabel.display("Alice") == "Alice")
}

@Test func defaultTitleCanTakeTheAppName() {
    #expect(Meeting.retitle("会议 2026-11-04 10:30", source: "飞书", prefix: "会议") == "飞书 2026-11-04 10:30")
    #expect(Meeting.retitle("Meeting 2026-11-04 10:30", source: "Feishu", prefix: "Meeting") == "Feishu 2026-11-04 10:30")
}

@Test func customTitleIsLeftAlone() {
    #expect(Meeting.retitle("周会", source: "飞书", prefix: "会议") == nil)
    #expect(Meeting.retitle("会议纪要讨论", source: "飞书", prefix: "会议") == nil)
}

@Test func exportUsesRealNameOverLabel() {
    let s = TranscriptSegment.fixture(label: "说话人 1")
    #expect(MarkdownExporter.displayName(s, ["说话人 1": "张三"]) == "张三")
    #expect(MarkdownExporter.displayName(s) == "说话人 1")
}

private extension TranscriptSegment {
    static func fixture(label: String?) -> TranscriptSegment {
        TranscriptSegment(versionID: UUID(), channel: .system, speakerLabel: label, start: 0, end: 1, text: "x")
    }
}

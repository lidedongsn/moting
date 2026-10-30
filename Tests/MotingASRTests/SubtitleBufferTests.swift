import Foundation
import Testing
import MotingCore
@testable import MotingASR

private func line(_ id: UUID = UUID(), _ text: String, final: Bool) -> SubtitleLine {
    SubtitleLine(id: id, channel: .mic, text: text, isFinal: final)
}

private func finalEvent(_ text: String) -> TranscriptEvent {
    let l = line(UUID(), text, final: true)
    return .final(l, TranscriptSegment(id: l.id, versionID: UUID(), channel: .mic, start: 0, end: 1, text: text))
}

@Test func bufferKeepsOnlyRecentLines() {
    var b = SubtitleBuffer(maxLines: 6)
    for i in 0..<10 { b.apply(finalEvent("第\(i)句")) }
    #expect(b.lines.count == 6)
    #expect(b.lines.map(\.text) == (4..<10).map { "第\($0)句" })
}

@Test func bufferUpdatesPartialInPlace() {
    var b = SubtitleBuffer()
    let id = UUID()
    b.apply(.partial(line(id, "你", final: false)))
    b.apply(.partial(line(id, "你好", final: false)))
    #expect(b.lines.count == 1)
    #expect(b.lines[0].text == "你好")
    #expect(!b.lines[0].isFinal)
    let l = line(id, "你好。", final: true)
    b.apply(.final(l, TranscriptSegment(id: id, versionID: UUID(), channel: .mic, start: 0, end: 1, text: l.text)))
    #expect(b.lines.count == 1)
    #expect(b.lines[0].isFinal)
    #expect(b.lines[0].text == "你好。")
}

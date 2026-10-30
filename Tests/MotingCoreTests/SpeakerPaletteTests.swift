import Foundation
import Testing
@testable import MotingCore

private func seg(_ ch: AudioChannel, _ s: Double, _ e: Double, _ label: String? = nil) -> TranscriptSegment {
    TranscriptSegment(versionID: UUID(), channel: ch, speakerLabel: label, start: s, end: e, text: "x")
}

@Test func meIsAlwaysZero() {
    let idx = SpeakerPalette.indices(for: [seg(.system, 0, 1, "说话人 1"), seg(.mic, 1, 2)])
    #expect(idx[.me] == 0)
    #expect(idx[.other("说话人 1")] == 1)
}

@Test func paletteCyclesAndIsStable() {
    let segs = (1...8).map { seg(.system, Double($0), Double($0) + 1, "说话人 \($0)") }
    let a = SpeakerPalette.indices(for: segs), b = SpeakerPalette.indices(for: segs.shuffled())
    #expect(Set(a.values) == Set(0...8))   // 0 是"我"
    // 编号按首次出现的时间，与数组顺序无关
    #expect(a == b)
}

@Test func unlabeledSystemIsOther() {
    #expect(seg(.system, 0, 1).speakerKey == .other("对方"))
    #expect(seg(.mic, 0, 1, "说话人 3").speakerKey == .me)
}

@Test func emptySegmentsGiveEmptyBar() {
    #expect(SpeakingTimeline.bins([], duration: 60, count: 10) == Array(repeating: nil, count: 10))
    #expect(SpeakingTimeline.bins([], duration: 0, count: 4) == Array(repeating: nil, count: 4))
}

@Test func binsPickDominantSpeaker() {
    let segs = [seg(.mic, 0, 4), seg(.system, 3, 10, "说话人 1")]
    let bins = SpeakingTimeline.bins(segs, duration: 10, count: 5)   // 每段 2 秒
    #expect(bins == [.me, .me, .other("说话人 1"), .other("说话人 1"), .other("说话人 1")])
}

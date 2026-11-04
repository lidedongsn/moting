import Foundation
import Testing
@testable import MotingCore

private let version = UUID()
private func seg(_ ch: AudioChannel, _ label: String?, _ start: Double, _ end: Double, _ text: String = "x") -> TranscriptSegment {
    TranscriptSegment(versionID: version, channel: ch, speakerLabel: label, start: start, end: end, text: text)
}

@Test func consecutiveSentencesBySameSpeakerBecomeOneTurn() {
    let turns = TranscriptTurns.group([seg(.mic, nil, 0, 2), seg(.mic, nil, 2.5, 4), seg(.system, "说话人 1", 5, 7)])
    #expect(turns.map(\.segments.count) == [2, 1])
    #expect(turns[0].speaker == .me)
    #expect(turns[1].speaker == .other("说话人 1"))
    #expect(turns[0].start == 0 && turns[0].end == 4)
}

@Test func longSilenceStartsANewTurn() {
    let turns = TranscriptTurns.group([seg(.mic, nil, 0, 2), seg(.mic, nil, 2 + TranscriptTurns.maxGap + 1, 40)])
    #expect(turns.count == 2)
}

@Test func longMonologueIsSplitSoClickingStillJumpsNearby() {
    let segments = stride(from: 0.0, to: 200, by: 10).map { seg(.mic, nil, $0, $0 + 9) }
    let turns = TranscriptTurns.group(segments)
    #expect(turns.count > 1)
    #expect(turns.allSatisfy { $0.end - $0.start <= TranscriptTurns.maxLength + 10 })
    #expect(turns.flatMap(\.segments).count == segments.count)
}

@Test func emptyTranscriptHasNoTurns() {
    #expect(TranscriptTurns.group([]).isEmpty)
}

@Test func unsortedInputIsOrderedByTime() {
    let turns = TranscriptTurns.group([seg(.system, "说话人 1", 5, 7), seg(.mic, nil, 0, 2)])
    #expect(turns.first?.speaker == .me)
}

@Test func findsTheTurnBeingPlayed() {
    let turns = TranscriptTurns.group([seg(.mic, nil, 0, 2), seg(.system, "说话人 1", 5, 7), seg(.mic, nil, 10, 12)])
    #expect(TranscriptTurns.index(in: turns, at: -1) == nil)
    #expect(TranscriptTurns.index(in: turns, at: 0) == 0)
    #expect(TranscriptTurns.index(in: turns, at: 6) == 1)
    #expect(TranscriptTurns.index(in: turns, at: 100) == 2)
}
